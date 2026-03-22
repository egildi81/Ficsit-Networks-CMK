const VERSION = "1.7.23";
// ── Navigation sections ───────────────────────────────────────
const _trainPages    = ['page-monitor', 'page-history', 'page-stats'];
const _stockagePages = ['page-stockage-info', 'page-stockage-config', 'page-stockage-update'];
const _dispatchPages = ['page-dispatch-live2', 'page-dispatch-config'];
const _sectionPages  = ['page-stockage-info', 'page-stockage-config', 'page-stockage-update', 'page-power', 'page-dispatch-live2', 'page-dispatch-config', 'page-logs', 'page-usine-info', 'page-usine-config'];
const _usinePages    = ['page-usine-info', 'page-usine-config'];

// Couleurs tags FIN / FIN tag colors
const LOG_TAG_COLORS = {
    LOGGER:     '#33cc55',
    DETAIL:     '#4488ff',
    TRAIN_TAB:  '#cccc00',
    DISPATCH:   '#00cccc',
    STOCKAGE:   '#aa44aa',
    CENTRAL:    '#ffc800',
    TRAIN_STATS:'#ff8800',
    TRAIN_MAP:  '#44cc99',
    POWER_MON:  '#ff66aa',
    STARTER:     '#cc2222',
    FAC_CENTRAL: '#ff00bf',
};
let _lastTrainPage    = 'page-monitor';
let _lastStockagePage = 'page-stockage-info';
let _lastDispatchPage = 'page-dispatch-live2';
let _lastUsinePage    = 'page-usine-info';

function switchSection(name, btn) {
    document.querySelectorAll('.section-btn').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    const trainsTabs    = document.getElementById('trains-tabs');
    const stockageTabs  = document.getElementById('stockage-tabs');
    const dispatchTabs  = document.getElementById('dispatch-tabs');
    const usineTabs     = document.getElementById('usine-tabs');
    // Masquer toutes les pages / Hide all pages
    _trainPages.forEach(id => document.getElementById(id).classList.remove('active'));
    _sectionPages.forEach(id => document.getElementById(id).classList.remove('active'));
    if (name === 'trains') {
        trainsTabs.style.display   = '';
        stockageTabs.style.display = 'none';
        dispatchTabs.style.display = 'none';
        usineTabs.style.display    = 'none';
        document.getElementById(_lastTrainPage).classList.add('active');
    } else if (name === 'stockage') {
        trainsTabs.style.display   = 'none';
        stockageTabs.style.display = '';
        dispatchTabs.style.display = 'none';
        usineTabs.style.display    = 'none';
        document.getElementById(_lastStockagePage).classList.add('active');
    } else if (name === 'dispatch') {
        trainsTabs.style.display   = 'none';
        stockageTabs.style.display = 'none';
        dispatchTabs.style.display = '';
        usineTabs.style.display    = 'none';
        document.getElementById(_lastDispatchPage).classList.add('active');
    } else if (name === 'usine') {
        trainsTabs.style.display   = 'none';
        stockageTabs.style.display = 'none';
        dispatchTabs.style.display = 'none';
        usineTabs.style.display    = '';
        document.getElementById(_lastUsinePage).classList.add('active');
    } else {
        trainsTabs.style.display   = 'none';
        stockageTabs.style.display = 'none';
        dispatchTabs.style.display = 'none';
        usineTabs.style.display    = 'none';
        document.getElementById('page-' + name).classList.add('active');
        if (name === 'logs') refreshLogs();
    }
}

// ── Navigation onglets (sous DISPATCH) ────────────────────────
function switchDispatchTab(name, btn) {
    _dispatchPages.forEach(id => document.getElementById(id).classList.remove('active'));
    document.querySelectorAll('#dispatch-tabs .tab').forEach(t => t.classList.remove('active'));
    _lastDispatchPage = name === 'live' ? 'page-dispatch-live2' : 'page-dispatch-config';
    document.getElementById(_lastDispatchPage).classList.add('active');
    btn.classList.add('active');
    if (name === 'config') renderDispatch2();
    if (name === 'live')   _dp2RenderLive();
}

// ── Navigation onglets (sous STOCKAGE) ────────────────────────
function switchStockTab(name, btn) {
    _stockagePages.forEach(id => document.getElementById(id).classList.remove('active'));
    document.querySelectorAll('#stockage-tabs .tab').forEach(t => t.classList.remove('active'));
    _lastStockagePage = 'page-stockage-' + name;
    document.getElementById(_lastStockagePage).classList.add('active');
    btn.classList.add('active');
}

// ── Navigation onglets (sous USINE) ───────────────────────────
function switchUsineTab(name, btn) {
    _usinePages.forEach(id => document.getElementById(id).classList.remove('active'));
    document.querySelectorAll('#usine-tabs .tab').forEach(t => t.classList.remove('active'));
    _lastUsinePage = 'page-usine-' + name;
    document.getElementById(_lastUsinePage).classList.add('active');
    btn.classList.add('active');
    if (name === 'config') _facRenderConfig();
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
// Fenêtre Check Perf filtrée par horodatage côté serveur / Time window filtered server-side by timestamp

function openCheckPerf() {
    document.getElementById('perf-modal').classList.add('open');
    loadCheckPerf(15, document.querySelector('.perf-range-btn.active'));
}

async function loadCheckPerf(minutes, btn) {
    document.querySelectorAll('.perf-range-btn').forEach(b => b.classList.remove('active'));
    if (btn) btn.classList.add('active');
    document.getElementById('perf-body').innerHTML = 'Chargement…';
    try {
        const r = await fetch(`/api/perf/trains?minutes=${minutes}`);
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

        // Ligne livraison si disponible et problématique / Delivery line if available and problematic
        const hasDelivery = t.delivery_rate !== null && t.delivery_rate !== undefined;
        const deliveryHtml = (hasDelivery && t.delivery_rate < 80) ? `
            <div style="font-size:0.72em;margin-top:3px">
                <span style="color:#555">chargé </span><span style="color:#aaa">${t.loaded_avg}</span>
                <span style="color:#555"> → livré </span>
                <span style="color:${t.delivery_rate < 25 ? '#f44' : '#fa0'}">${t.delivered_avg} (${t.delivery_rate}%)</span>
            </div>` : '';

        const dispatchHtml = t.dispatch_candidate
            ? `<span style="color:#00cccc;font-size:0.68em;font-weight:600;margin-left:6px">🎯 Candidat DISPATCH</span>`
            : '';

        html += `
        <div style="margin-bottom:10px;border-left:3px solid ${c};padding-left:10px">
            <div style="display:flex;align-items:center;gap:8px;margin-bottom:3px;flex-wrap:wrap">
                <span style="color:#555;font-size:0.7em;font-weight:700">#${i+1}</span>
                <span style="color:#ddd;font-size:0.85em;font-weight:700">${esc(t.name)}</span>
                <span style="font-size:0.75em">${ic}</span>
                <span style="color:${c};font-size:0.72em;font-weight:600">${esc(t.label)}</span>
                ${dispatchHtml}
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
            ${deliveryHtml}
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

    // Alertes buffers cassés / Broken buffer alerts
    if (Array.isArray(d.buffer_alerts) && d.buffer_alerts.length > 0) {
        html += `<div style="margin-bottom:14px;border-left:3px solid #f44;padding-left:10px">
            <div style="color:#f44;font-size:0.7em;font-weight:700;letter-spacing:1px;margin-bottom:6px">BUFFER(S) INTROUVABLE(S)</div>`;
        for (const ba of d.buffer_alerts) {
            html += `<div style="font-size:0.78em;color:#ccc;padding:3px 0;border-bottom:1px solid #1a1a1a">
                Route <span style="color:#00cccc">${esc(ba.route)}</span> →
                buffer <span style="color:#f44;font-family:monospace">${esc(ba.buffer)}</span>
                <span style="color:#555;font-size:0.88em"> (absent du dernier scan CENTRAL)</span>
            </div>`;
        }
        html += `</div>`;
    }

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
    if (_isDragging) return;  // ne pas re-render pendant un drag / do not re-render while dragging
    const zones = zoneConfig && zoneConfig.zones;
    if (!zones || !zones.length) {
        grid.innerHTML = '<div class="stock-empty">Aucune zone configurée — définissez vos zones dans l\'onglet Configuration</div>';
        return;
    }
    // Lookup conteneurs par nick / Container lookup by nick
    const byNick = {};
    for (const c of ((centralData && centralData.containers) || [])) byNick[c.nick] = c;

    const now = Date.now() / 1000;
    const payloadStale = centralData && centralData.server_ts && (now - centralData.server_ts) > 120;

    // Agrège, retourne items triés + flag hasStale si un conteneur est hors-ligne
    // Aggregates, returns sorted items + hasStale flag if any container is offline
    function aggr(nicks) {
        let slotsTotal = 0, slotsUsed = 0, totalItems = 0, hasStale = false;
        const itemsMap = {};
        for (const nick of nicks) {
            const c = byNick[nick]; if (!c) continue;
            if (c.stale) { hasStale = true; continue; }  // satellite hors-ligne / offline satellite
            slotsTotal += c.slotsTotal || 0;
            slotsUsed  += c.slotsUsed  || 0;
            totalItems += c.totalItems  || 0;
            for (const [id, item] of Object.entries(c.items || {})) {
                if (!itemsMap[id]) itemsMap[id] = { name: item.name, count: 0 };
                itemsMap[id].count += item.count;
            }
        }
        const fillRate = slotsTotal > 0 ? Math.floor(slotsUsed / slotsTotal * 1000) / 10 : 0;
        const items = Object.values(itemsMap).sort((a, b) => b.count - a.count)
            .map(it => ({ ...it, pct: totalItems > 0 ? Math.round(it.count / totalItems * 100) : 0 }));
        return { slotsTotal, slotsUsed, fillRate, totalItems, items, hasStale };
    }

    // Construire le cache pour la modal (format compatible openStockModal)
    // Build cache for modal (openStockModal-compatible format)
    _stockageCache = zones.map(zone => {
        const allNicks = [...(zone.containers || []), ...((zone.subzones || []).flatMap(sz => sz.containers || []))];
        const za = aggr(allNicks);
        const subzones = [];
        if (zone.subzones && zone.subzones.length > 0) {
            if (zone.containers && zone.containers.length) subzones.push({ name: zone.mainLabel || 'Principal', ...aggr(zone.containers) });
            for (const sz of zone.subzones) subzones.push({ name: sz.name, ...aggr(sz.containers || []) });
        }
        const zoneHasStale = za.hasStale || subzones.some(s => s.hasStale);
        return { zone: zone.name, ...za, subzones, hasStale: zoneHasStale };
    });

    const sorted = _sortByOrder(_stockageCache);
    grid.innerHTML = sorted.map(z => {
        const fill = z.fillRate, fillColor = fill >= 80 ? '#ee3333' : fill >= 50 ? '#eeee22' : '#22ee22';
        const offlineBadge = z.hasStale ? '<span class="stock-offline-badge">Hors ligne</span>' : '';

        let itemsBlock;
        if (z.subzones && z.subzones.length > 0) {
            const visibleSz = _stockCompact ? z.subzones.slice(0, 4) : z.subzones;
            const hiddenCount = _stockCompact ? z.subzones.length - visibleSz.length : 0;
            itemsBlock = `<div class="stock-subzones">${visibleSz.map(sz => {
                const sf = sz.fillRate ?? 0, sc = sf >= 80 ? '#ee3333' : sf >= 50 ? '#eeee22' : '#22ee22';
                const top3 = sz.items.slice(0, 3);
                const szOffline = sz.hasStale ? '<span class="stock-offline-badge">Hors ligne</span>' : '';
                return `<div class="stock-subzone${sz.hasStale ? ' stock-subzone-stale' : ''}">
                    <div class="stock-subzone-header"><span class="stock-subzone-name">${esc(sz.name)}</span>${szOffline}<span class="stock-subzone-fill" style="color:${sc}">${sf}%</span></div>
                    <div class="stock-subzone-bar-bg"><div class="stock-subzone-bar" style="width:${sf}%;background:${sc}"></div></div>
                    ${_stockCompact ? '' : `<div class="stock-subzone-meta">${sz.slotsUsed} / ${sz.slotsTotal} slots · ${sz.totalItems} items</div>
                    ${top3.map(it => `<div class="stock-item-row"><span class="stock-item-name">${esc(it.name)}</span><span class="stock-item-count">${it.count}</span><span class="stock-item-pct">${it.pct}%</span></div>`).join('')}`}
                </div>`;
            }).join('')}${hiddenCount > 0 ? `<div style="color:#555;font-size:0.68em;padding:3px 6px">+${hiddenCount} autre${hiddenCount > 1 ? 's' : ''}…</div>` : ''}</div>`;
        } else {
            const top = _stockCompact ? [] : z.items.slice(0, 3);
            itemsBlock = `<div class="stock-items">${top.length
                ? top.map(it => `<div class="stock-item-row"><span class="stock-item-name">${esc(it.name)}</span><span class="stock-item-count">${it.count}</span><span class="stock-item-pct">${it.pct}%</span></div>`).join('')
                : _stockCompact ? '' : '<div class="stock-empty">Aucun item</div>'}</div>`;
        }
        return `
            <div class="stock-card${payloadStale ? ' stock-stale' : ''}" draggable="true" data-zone="${esc(z.zone)}"
                 onclick="openStockModal('${esc(z.zone)}')" title="Voir tous les items" style="cursor:pointer">
                <div class="stock-card-header"><span class="stock-zone">${esc(z.zone)}</span>${offlineBadge}<span class="stock-fill" style="color:${fillColor}">${fill}%</span></div>
                <div class="stock-bar-bg"><div class="stock-bar" style="width:${fill}%;background:${fillColor}"></div></div>
                <div class="stock-meta">${z.slotsUsed} / ${z.slotsTotal} slots · ${z.totalItems} items</div>
                ${itemsBlock}
            </div>`;
    }).join('');
    _setupStockageDrag();
}

// ── Config USINE DnD ─────────────────────────────────────────
let _facZones      = [];     // [{id, name, machines:[nick], subzones:[{id, name, machines:[nick]}]}]
let _facAllMachs   = [];     // [{nick, class, satellite, prod}]
let _facDragNick   = null;   // nick machine en cours de drag / nick of dragged machine
let _facIdCnt      = 0;
let _facCollapsed  = new Set();
let _facPoolFilter = '';
let _facZonesSrch  = '';
let _facByNick     = {};     // lookup live par nick, mis à jour à chaque render / live nick lookup, updated each render

function _facAssigned() {
    const s = new Set();
    for (const z of _facZones) {
        z.machines.forEach(n => s.add(n));
        z.subzones.forEach(sz => sz.machines.forEach(n => s.add(n)));
    }
    return s;
}
function _facRemoveNick(nick) {
    for (const z of _facZones) {
        z.machines = z.machines.filter(n => n !== nick);
        z.subzones.forEach(sz => { sz.machines = sz.machines.filter(n => n !== nick); });
    }
}
function _facDragStart(ev, nick) { _facDragNick = nick; ev.target.classList.add('dragging'); ev.dataTransfer.effectAllowed = 'move'; }
function _facDragEnd(ev)         { ev.target.classList.remove('dragging'); _facDragNick = null; }
function _facLeave(ev)           { if (!ev.currentTarget.contains(ev.relatedTarget)) ev.currentTarget.classList.remove('drag-over'); }
function _facDrop(ev, zoneId, szId) {
    ev.preventDefault();
    ev.currentTarget.classList.remove('drag-over');
    if (!_facDragNick) return;
    _facRemoveNick(_facDragNick);
    if (zoneId >= 0) {
        const z = _facZones.find(z => z.id === zoneId);
        if (!z) return;
        if (szId < 0) z.machines.push(_facDragNick);
        else { const sz = z.subzones.find(s => s.id === szId); if (sz) sz.machines.push(_facDragNick); }
    }
    _facRenderConfig();
}
function _facAddZone()               { _facZones.push({ id: _facIdCnt++, name: 'Nouvelle zone', machines: [], subzones: [] }); _facRenderConfig(); }
function _facRemoveZone(id)          { _facZones = _facZones.filter(z => z.id !== id); _facRenderConfig(); }
function _facAddSubzone(zid)         { const z = _facZones.find(z => z.id === zid); if (z) z.subzones.push({ id: _facIdCnt++, name: 'Sous-zone', machines: [] }); _facRenderConfig(); }
function _facRemoveSubzone(zid, sid) { const z = _facZones.find(z => z.id === zid); if (z) z.subzones = z.subzones.filter(s => s.id !== sid); _facRenderConfig(); }
function _facRenameZone(id, v)         { const z = _facZones.find(z => z.id === id); if (z) z.name = v; }
function _facRenameMainLabel(id, v)    { const z = _facZones.find(z => z.id === id); if (z) z.mainLabel = v; }
function _facRenameSz(zid, sid, v)     { const z = _facZones.find(z => z.id === zid); if (z) { const s = z.subzones.find(s => s.id === sid); if (s) s.name = v; } }
function _facToggleZone(id)          { _facCollapsed.has(id) ? _facCollapsed.delete(id) : _facCollapsed.add(id); _facRenderConfig(); }

function _facApplyPoolFilter(v) {
    _facPoolFilter = v;
    const drop = document.getElementById('fac-pool-drop');
    if (!drop) return;
    const term = v.toLowerCase();
    drop.querySelectorAll('.fac-mach-card').forEach(card => {
        const text = card.textContent.toLowerCase();
        card.style.display = !term || text.includes(term) ? '' : 'none';
    });
}

function _facApplyZonesSearch(v) {
    _facZonesSrch = v;
    const term = v.toLowerCase();
    document.querySelectorAll('.fac-cfg-zones .fac-zone-cfg-card').forEach(card => {
        if (!term) { card.style.display = ''; return; }
        const zoneId = parseInt(card.dataset.zoneId);
        const zone = _facZones.find(z => z.id === zoneId);
        if (!zone) { card.style.display = ''; return; }
        const allNicks = [...zone.machines, ...zone.subzones.flatMap(sz => sz.machines)];
        card.style.display = allNicks.some(n => n.toLowerCase().includes(term)) ? '' : 'none';
    });
}

function _facShortClass(cls) {
    return (cls || '').replace(/^Build_/, '').replace(/Mk\d+_C$/, '').replace(/_C$/, '');
}

function _facMachCard(m) {
    const prod = m.prod ?? 0;
    const prodColor = prod >= 80 ? '#99ff00' : prod >= 50 ? '#ffcc00' : '#ff4444';
    return `<div class="fac-mach-card" draggable="true"
                 ondragstart="_facDragStart(event,'${esc(m.nick)}')" ondragend="_facDragEnd(event)"
                 title="${esc(m.satellite || '')} — ${esc(_facShortClass(m.class))}">
        <div class="fac-mach-nick">${esc(m.nick)}</div>
        ${m.class ? `<div class="fac-mach-cls">${esc(_facShortClass(m.class))}</div>` : ''}
        ${m.satellite ? `<div class="fac-mach-cls" style="color:#667766">${esc(m.satellite)}</div>` : ''}
        ${prod > 0 ? `<div class="fac-mach-prod">${prod.toFixed(0)}%</div><div class="fac-mach-bar-bg"><div class="fac-mach-bar" style="width:${Math.min(prod,100)}%;background:${prodColor}"></div></div>` : ''}
    </div>`;
}

function _facDropArea(zoneId, szId, nickList) {
    const cards = nickList.map(nick => {
        const m = _facAllMachs.find(m => m.nick === nick) || { nick, class: '', satellite: '', prod: 0 };
        return _facMachCard(m);
    }).join('');
    return `<div class="fac-drop-area"
                 ondragover="event.preventDefault()"
                 ondragenter="this.classList.add('drag-over')"
                 ondragleave="_facLeave(event)"
                 ondrop="_facDrop(event,${zoneId},${szId})">
        ${cards}<div class="fac-drop-hint">${nickList.length ? '' : 'Glisser ici'}</div>
    </div>`;
}

function _facRenderConfig() {
    const el = document.getElementById('usine-config-content');
    if (!el) return;
    const assigned = _facAssigned();
    const pool = _facAllMachs.filter(m => !assigned.has(m.nick));

    const zonesHtml = _facZones.map(z => {
        const collapsed  = _facCollapsed.has(z.id);
        const totalMachs = z.machines.length + z.subzones.reduce((s, sz) => s + sz.machines.length, 0);
        const body = collapsed ? '' : `
            ${z.subzones.length > 0 ? `<div class="fac-subzone-cfg-header" style="padding:5px 14px">
                <input class="fac-subzone-cfg-name" value="${esc(z.mainLabel)}" placeholder="Principal"
                       onchange="_facRenameMainLabel(${z.id},this.value)">
            </div>` : ''}
            ${_facDropArea(z.id, -1, z.machines)}
            ${z.subzones.map(sz => `
                <div class="fac-subzone-cfg-card">
                    <div class="fac-subzone-cfg-header">
                        <input class="fac-subzone-cfg-name" value="${esc(sz.name)}" placeholder="Nom" onchange="_facRenameSz(${z.id},${sz.id},this.value)">
                        <button class="fac-btn-sm fac-btn-del" onclick="_facRemoveSubzone(${z.id},${sz.id})">✕</button>
                    </div>
                    ${_facDropArea(z.id, sz.id, sz.machines)}
                </div>`).join('')}`;
        return `
        <div class="fac-zone-cfg-card" data-zone-id="${z.id}">
            <div class="fac-zone-cfg-header">
                <button class="fac-btn-collapse" onclick="_facToggleZone(${z.id})" title="${collapsed ? 'Développer' : 'Réduire'}">${collapsed ? '▸' : '▾'}</button>
                <input class="fac-zone-cfg-name" value="${esc(z.name)}" placeholder="Nom de la zone" onchange="_facRenameZone(${z.id},this.value)">
                ${collapsed ? `<span style="color:#666;font-size:0.68em;white-space:nowrap">${totalMachs} mach.</span>` : ''}
                <button class="fac-btn-sm" onclick="_facAddSubzone(${z.id})">+ Sous-zone</button>
                <button class="fac-btn-sm fac-btn-del" onclick="_facRemoveZone(${z.id})">✕</button>
            </div>
            ${body}
        </div>`;
    }).join('') || '<div class="stock-empty" style="margin-top:8px">Cliquez sur "+ Zone" pour commencer</div>';

    const poolCards = pool.map(m => _facMachCard(m)).join('')
        || '<div class="fac-drop-hint">Toutes assignées</div>';

    el.innerHTML = `
        <div class="fac-cfg-actions">
            <button class="stock-purge-btn" onclick="_facAddZone()">+ Zone</button>
            <button class="stock-purge-btn" onclick="_saveFactoryZoneConfig()">Sauvegarder</button>
            <span id="fac-cfg-status" style="font-size:0.78em;color:#888"></span>
        </div>
        <div class="fac-cfg-layout">
            <div class="fac-cfg-pool">
                <div class="fac-cfg-pool-title">Disponibles</div>
                <input class="fac-cfg-filter" id="fac-pool-filter" type="text" placeholder="Filtrer..."
                       value="${esc(_facPoolFilter)}" oninput="_facApplyPoolFilter(this.value)">
                <div class="fac-drop-area" id="fac-pool-drop" style="flex-direction:column"
                     ondragover="event.preventDefault()"
                     ondragenter="this.classList.add('drag-over')"
                     ondragleave="_facLeave(event)"
                     ondrop="_facDrop(event,-1,-1)">${poolCards}</div>
            </div>
            <div class="fac-cfg-zones">
                <input class="fac-cfg-filter" id="fac-zones-search" type="text"
                       placeholder="Chercher une machine dans les zones..."
                       value="${esc(_facZonesSrch)}" oninput="_facApplyZonesSearch(this.value)"
                       style="margin-bottom:10px">
                ${zonesHtml}
            </div>
        </div>`;

    if (_facPoolFilter) _facApplyPoolFilter(_facPoolFilter);
    if (_facZonesSrch)  _facApplyZonesSearch(_facZonesSrch);
}

function renderFactoryConfig(fac, zoneConfig) {
    // Construire la liste des machines depuis les données CENTRAL / Build machine list from CENTRAL data
    if (fac && fac.zones) {
        _facAllMachs = fac.zones.flatMap(z =>
            (z.machines || []).map(m => ({
                nick:      m.nick,
                class:     m.class || '',
                satellite: z.name || '',
                prod:      m.productivity ?? 0
            }))
        );
    }
    // Init zones depuis config serveur / Init zones from server config
    const cfgZones = zoneConfig && zoneConfig.zones;
    _facIdCnt = 0; _facZones = [];
    if (cfgZones && cfgZones.length) {
        for (const z of cfgZones) {
            _facZones.push({
                id: _facIdCnt++, name: z.name, mainLabel: z.mainLabel || '',
                machines: [...(z.machines || [])],
                subzones: (z.subzones || []).map(sz => ({ id: _facIdCnt++, name: sz.name, machines: [...(sz.machines || [])] }))
            });
        }
    }
    _facRenderConfig();
}

function _saveFactoryZoneConfig() {
    const config = {
        zones: _facZones.map(z => ({
            name: z.name,
            mainLabel: z.mainLabel || '',
            machines: z.machines,
            subzones: z.subzones.map(sz => ({ name: sz.name, machines: sz.machines }))
        }))
    };
    fetch('/api/factory/zone-config', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(config) })
        .then(r => {
            const st = document.getElementById('fac-cfg-status');
            if (!r.ok) { if (st) st.textContent = `Erreur HTTP ${r.status}`; return; }
            _factoryZoneConfig = config;
            _prevJson.factory = null;  // forcer re-render INFO / force INFO re-render
            if (_lastFactoryData) setTimeout(() => renderFactory(_lastFactoryData), 0);
            if (st) { st.textContent = 'Sauvegardé ✓'; setTimeout(() => { if (st) st.textContent = ''; }, 2000); }
        })
        .catch(() => { const st = document.getElementById('fac-cfg-status'); if (st) st.textContent = 'Erreur réseau'; });
}

// ── Config DnD ───────────────────────────────────────────────
let _stkZones      = [];     // [{id, name, containers:[nick], subzones:[{id, name, containers:[nick]}]}]
let _stkAllConts   = [];     // [{satellite, nick, slotsTotal, slotsUsed, fillRate, totalItems}]
let _stkDragNick   = null;   // nick du conteneur en cours de drag / nick of dragged container
let _stkIdCnt      = 0;
let _stkCollapsed  = new Set(); // IDs de zones réduites / collapsed zone IDs
let _stkPoolFilter = '';        // filtre texte pool disponibles / available pool text filter
let _stkZonesSrch  = '';        // recherche conteneur dans zones / container search in zones

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
function _stkAddZone()             { _stkZones.push({ id: _stkIdCnt++, name: 'Nouvelle zone', mainLabel: '', containers: [], subzones: [] }); _stkRenderConfig(); }
function _stkRemoveZone(id)        { _stkZones = _stkZones.filter(z => z.id !== id); _stkRenderConfig(); }
function _stkAddSubzone(zid)       { const z = _stkZones.find(z => z.id === zid); if (z) z.subzones.push({ id: _stkIdCnt++, name: 'Sous-zone', containers: [] }); _stkRenderConfig(); }
function _stkRemoveSubzone(zid, sid) { const z = _stkZones.find(z => z.id === zid); if (z) z.subzones = z.subzones.filter(s => s.id !== sid); _stkRenderConfig(); }
function _stkRenameZone(id, v)        { const z = _stkZones.find(z => z.id === id); if (z) z.name = v; }
function _stkRenameMainLabel(id, v)   { const z = _stkZones.find(z => z.id === id); if (z) z.mainLabel = v; }
function _stkRenameSz(zid, sid, v)    { const z = _stkZones.find(z => z.id === zid); if (z) { const s = z.subzones.find(s => s.id === sid); if (s) s.name = v; } }
function _stkToggleZone(id)           { _stkCollapsed.has(id) ? _stkCollapsed.delete(id) : _stkCollapsed.add(id); _stkRenderConfig(); }

// Filtre en direct dans le pool — ne re-render pas, cache/affiche les cards existantes
// Live filter in pool — no re-render, hides/shows existing cards
function _stkApplyPoolFilter(v) {
    _stkPoolFilter = v;
    const drop = document.getElementById('stk-pool-drop');
    if (!drop) return;
    const term = v.toLowerCase();
    drop.querySelectorAll('.stk-cont-card').forEach(card => {
        const text = card.textContent.toLowerCase();
        card.style.display = !term || text.includes(term) ? '' : 'none';
    });
}

// Recherche conteneur dans les zones configurées / Container search in configured zones
function _stkApplyZonesSearch(v) {
    _stkZonesSrch = v;
    const term = v.toLowerCase();
    document.querySelectorAll('.stk-cfg-zones .stk-zone-card').forEach(card => {
        if (!term) { card.style.display = ''; return; }
        const zoneId = parseInt(card.dataset.zoneId);
        const zone = _stkZones.find(z => z.id === zoneId);
        if (!zone) { card.style.display = ''; return; }
        const allNicks = [...zone.containers, ...zone.subzones.flatMap(sz => sz.containers)];
        card.style.display = allNicks.some(n => n.toLowerCase().includes(term)) ? '' : 'none';
    });
}

function _stkContCard(c) {
    const fill = c.fillRate ?? 0, color = fill >= 80 ? '#ee3333' : fill >= 50 ? '#eeee22' : '#22ee22';
    return `<div class="stk-cont-card" draggable="true"
                 ondragstart="_stkDragStart(event,'${esc(c.nick)}')" ondragend="_stkDragEnd(event)"
                 title="${esc(c.satellite || '')} — ${c.slotsUsed ?? 0}/${c.slotsTotal ?? 0} slots">
        <div class="stk-cont-nick">${esc(c.nick)}</div>
        ${c.satellite ? `<div class="stk-cont-sat">${esc(c.satellite)}</div>` : ''}
        ${fill > 0 ? `<div class="stk-cont-fill">${fill}%</div><div class="stk-cont-bar-bg"><div class="stk-cont-bar" style="width:${fill}%;background:${color}"></div></div>` : ''}
    </div>`;
}
function _stkDropArea(zoneId, szId, nickList) {
    const cards = nickList.map(nick => {
        const c = _stkAllConts.find(c => c.nick === nick) || { nick, satellite: '', fillRate: 0, slotsTotal: 0, slotsUsed: 0 };
        return _stkContCard(c);
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

    const zonesHtml = _stkZones.map(z => {
        const collapsed = _stkCollapsed.has(z.id);
        const totalConts = z.containers.length + z.subzones.reduce((s, sz) => s + sz.containers.length, 0);
        const body = collapsed ? '' : `
            ${z.subzones.length > 0 ? `<div class="stk-subzone-header" style="padding:5px 14px">
                <input class="stk-subzone-name-input" value="${esc(z.mainLabel)}" placeholder="Principal"
                       onchange="_stkRenameMainLabel(${z.id},this.value)">
            </div>` : ''}
            ${_stkDropArea(z.id, -1, z.containers)}
            ${z.subzones.map(sz => `
                <div class="stk-subzone-card">
                    <div class="stk-subzone-header">
                        <input class="stk-subzone-name-input" value="${esc(sz.name)}" placeholder="Nom" onchange="_stkRenameSz(${z.id},${sz.id},this.value)">
                        <button class="stk-btn-sm stk-btn-del" onclick="_stkRemoveSubzone(${z.id},${sz.id})">✕</button>
                    </div>
                    ${_stkDropArea(z.id, sz.id, sz.containers)}
                </div>`).join('')}`;
        return `
        <div class="stk-zone-card" data-zone-id="${z.id}">
            <div class="stk-zone-header">
                <button class="stk-btn-collapse" onclick="_stkToggleZone(${z.id})" title="${collapsed ? 'Développer' : 'Réduire'}">${collapsed ? '▸' : '▾'}</button>
                <input class="stk-zone-name-input" value="${esc(z.name)}" placeholder="Nom de la zone" onchange="_stkRenameZone(${z.id},this.value)">
                ${collapsed ? `<span style="color:#666;font-size:0.68em;white-space:nowrap">${totalConts} cont.</span>` : ''}
                <button class="stk-btn-sm" onclick="_stkAddSubzone(${z.id})">+ Sous-zone</button>
                <button class="stk-btn-sm stk-btn-del" onclick="_stkRemoveZone(${z.id})">✕</button>
            </div>
            ${body}
        </div>`;
    }).join('') || '<div class="stock-empty" style="margin-top:8px">Cliquez sur "+ Zone" pour commencer</div>';

    const poolCards = pool.map(c => _stkContCard(c)).join('')
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
                <input class="stk-cfg-filter" id="stk-pool-filter" type="text" placeholder="Filtrer..."
                       value="${esc(_stkPoolFilter)}" oninput="_stkApplyPoolFilter(this.value)">
                <div class="stk-drop-area" id="stk-pool-drop" style="flex-direction:column"
                     ondragover="event.preventDefault()"
                     ondragenter="this.classList.add('drag-over')"
                     ondragleave="_stkLeave(event)"
                     ondrop="_stkDrop(event,-1,-1)">${poolCards}</div>
            </div>
            <div class="stk-cfg-zones">
                <input class="stk-cfg-filter" id="stk-zones-search" type="text"
                       placeholder="Chercher un conteneur dans les zones..."
                       value="${esc(_stkZonesSrch)}" oninput="_stkApplyZonesSearch(this.value)"
                       style="margin-bottom:10px">
                ${zonesHtml}
            </div>
        </div>`;

    // Ré-appliquer filtres après re-render (drag/drop) / Re-apply filters after re-render (drag/drop)
    if (_stkPoolFilter) _stkApplyPoolFilter(_stkPoolFilter);
    if (_stkZonesSrch)  _stkApplyZonesSearch(_stkZonesSrch);
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
                id: _stkIdCnt++, name: z.name, mainLabel: z.mainLabel || '',
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
            mainLabel: z.mainLabel || '',
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

// ── Satellite update (MISE À JOUR tab) ───────────────────────
let _satVersionsCache      = {};
let _satUpdateResultsCache = {};
let _satLatestVersion      = null;
let _satShowOutdatedOnly   = false;  // filtre "obsolètes seulement" / "outdated only" filter

function renderStockageUpdate(satVersions, satUpdateResults, latestVersion) {
    const el = document.getElementById('stockage-update-content');
    if (!el) return;
    _satVersionsCache      = satVersions      || {};
    _satUpdateResultsCache = satUpdateResults  || {};
    _satLatestVersion      = latestVersion     || null;

    const satListFull = Object.values(_satVersionsCache);
    const satList = _satShowOutdatedOnly
        ? satListFull.filter(s => !latestVersion || s.version !== latestVersion)
        : satListFull;
    if (!satListFull.length) {
        el.innerHTML = '<div class="stock-empty" style="padding:32px">Aucun satellite connu — en attente de données...</div>';
        return;
    }

    const outdated = satListFull.filter(s => latestVersion && s.version !== latestVersion);

    const cards = satList.map(sat => {
        const result    = _satUpdateResultsCache[sat.addr] || null;
        const isUpToDate = latestVersion && sat.version === latestVersion;
        const status     = result ? result.status : null;

        let badge = '';
        if (status === 'updated') {
            badge = `<span class="stk-upd-badge stk-upd-ok">✓ Mis à jour → v${esc(result.new_version)}</span>`;
        } else if (status === 'rebooting') {
            badge = `<span class="stk-upd-badge stk-upd-pending">↻ Redémarrage...</span>`;
        } else if (status === 'en attente') {
            badge = `<span class="stk-upd-badge stk-upd-pending">⏳ En attente...</span>`;
        } else if (status === 'timeout') {
            badge = `<span class="stk-upd-badge stk-upd-timeout">⚠ Timeout</span>`;
        } else if (isUpToDate) {
            badge = `<span class="stk-upd-badge stk-upd-ok">✓ À jour</span>`;
        } else if (latestVersion) {
            badge = `<span class="stk-upd-badge stk-upd-old">↑ Obsolète</span>`;
        }

        const busy       = status === 'rebooting' || status === 'en attente';
        const btnDisabled = isUpToDate || busy;
        const btnHtml = `<button class="stk-upd-btn" ${btnDisabled ? 'disabled' : `onclick="_satReboot('${esc(sat.addr)}')"`}>Mettre à jour</button>`;

        return `<div class="stk-upd-card">
            <div class="stk-upd-card-header">
                <span class="stk-upd-nick">${esc(sat.nick)}</span>
                ${badge}
            </div>
            <div class="stk-upd-versions">
                <span class="stk-upd-ver-cur">v${esc(sat.version)}</span>
                <span class="stk-upd-ver-arrow">→</span>
                <span class="stk-upd-ver-latest${isUpToDate ? ' stk-upd-ver-same' : ' stk-upd-ver-new'}">v${esc(latestVersion || '?')}</span>
            </div>
            ${btnHtml}
        </div>`;
    }).join('');

    el.innerHTML = `
        <div class="stk-upd-header">
            <div class="stk-upd-title-row">
                <span class="stk-upd-latest-label">Dernière version :</span>
                <span class="stk-upd-latest-ver">v${esc(latestVersion || '?')}</span>
                <span class="stk-upd-sat-count">${satList.length} satellite${satList.length > 1 ? 's' : ''}</span>
            </div>
            <div class="stk-upd-actions">
                <button class="stock-purge-btn" onclick="_satRebootAll()">Tout mettre à jour</button>
                ${outdated.length > 0
                    ? `<button class="stock-purge-btn${_satShowOutdatedOnly ? ' stk-upd-filter-active' : ''}" onclick="_satToggleOutdatedFilter()">Obsolètes (${outdated.length})</button>`
                    : ''}
            </div>
        </div>
        <div class="stk-upd-grid">${cards}</div>`;
}

function _satReboot(addr) {
    fetch('/api/stockage/satellite/reboot', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ addrs: [addr] })
    }).then(() => { _prevJson.sat_update = null; }).catch(e => console.error('reboot', e));
}
function _satRebootAll() {
    const addrs = Object.keys(_satVersionsCache);
    if (!addrs.length) return;
    fetch('/api/stockage/satellite/reboot', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ addrs })
    }).then(() => { _prevJson.sat_update = null; }).catch(e => console.error('reboot', e));
}
function _satToggleOutdatedFilter() {
    _satShowOutdatedOnly = !_satShowOutdatedOnly;
    _prevJson.sat_update = null;  // force re-render
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
const _prevJson = { trains: null, trips: null, stats: null, stockage_info: null, stockage_discovery: null, power: null, dispatch: null, sat_update: null, factory: null, factory_zone_config: null };
let _factoryZoneConfig   = { zones: [] };  // config zones usine persistée / persisted factory zone config
let _lastFactoryData     = null;           // dernier snapshot factory reçu / last factory snapshot received
let _facCompact          = true;           // true=vue agrégée recettes / false=vue machines individuelles
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
        const _uj = JSON.stringify({ v: data.satellite_versions || {}, r: data.sat_update_results || {} });
        if (_uj !== _prevJson.sat_update) {
            _prevJson.sat_update = _uj;
            rTimes.sat_update = _t('sat-upd', () => renderStockageUpdate(data.satellite_versions || {}, data.sat_update_results || {}, data.sat_latest_version || null));
        }
        _dpUpdateLists(data);
        if (_dj !== _prevJson.dispatch) { _prevJson.dispatch = _dj;  rTimes.dispatch = _t('dispatch', () => renderDispatch(data.dispatch || null, data.dispatch_routes ?? null)); }
        if (document.getElementById('page-logs').classList.contains('active')) { refreshLogs(); }
        if (data.factory) _lastFactoryData = data.factory;
        const _fj = JSON.stringify(data.factory || null);
        if (_fj !== _prevJson.factory) {
            _prevJson.factory = _fj;
            rTimes.factory = _t('factory', () => renderFactory(data.factory || null));
            // Mettre à jour les machines dans le pool config si la page est visible
            // Update machines in config pool if config page is visible
            if (data.factory && data.factory.zones) {
                _facAllMachs = data.factory.zones.flatMap(z =>
                    (z.machines || []).map(m => ({ nick: m.nick, class: m.class || '', satellite: z.name || '', prod: m.productivity ?? 0 }))
                );
            }
            if (document.getElementById('page-usine-config').classList.contains('active')) _facRenderConfig();
        }
        const _fzcj = JSON.stringify(data.factory_zone_config || null);
        if (_fzcj !== _prevJson.factory_zone_config) {
            _prevJson.factory_zone_config = _fzcj;
            _factoryZoneConfig = data.factory_zone_config || _factoryZoneConfig;
            _t('fac-cfg', () => renderFactoryConfig(data.factory || null, _factoryZoneConfig));
            _prevJson.factory = null;  // forcer re-render INFO avec nouveaux groupements / force INFO re-render with new groupings
        }

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
let _dpOnline        = false; // DISPATCH en ligne et configuré / DISPATCH online and configured
let _dpEditingIndex  = -1;   // index route en cours d'édition (-1 = aucune)
let _dpKnownStations = new Set();
let _dpKnownBuffers      = new Map();  // Map<value, label> — value=nom réel, label=affichage avec parent / value=actual name, label=display with parent
let _dpZoneConfigHash    = '';         // hash dernière config zones — évite rebuild datalist inutile / last zone config hash — avoids unnecessary datalist rebuild
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
    // Rebuild datalist buffers uniquement si la config a changé (évite de fermer le dropdown)
    // Rebuild buffer datalist only when config changed (avoids closing the open dropdown)
    const zc = data.stockage_zone_config;
    const zcHash = JSON.stringify(zc);
    if (zcHash !== _dpZoneConfigHash) {
        _dpZoneConfigHash = zcHash;
        const newBufMap = new Map();
        if (zc && Array.isArray(zc.zones)) {
            zc.zones.forEach(z => {
                if (!z.name) return;
                newBufMap.set(z.name, z.name);
                // Groupe principal (mainLabel) — CENTRAL envoie BUF:(zone) mainLabel / main group — CENTRAL sends BUF:(zone) mainLabel
                if (z.mainLabel) { const lbl = `(${z.name}) ${z.mainLabel}`; newBufMap.set(lbl, lbl); }
                if (z.subzones) z.subzones.forEach(sz => {
                    if (sz.name) { const lbl = `(${z.name}) ${sz.name}`; newBufMap.set(lbl, lbl); }
                });
            });
        }
        if (newBufMap.size > 0) {
            _dpKnownBuffers = newBufMap;
            const dlBuf = document.getElementById('dp-dl-buffers');
            if (dlBuf) {
                dlBuf.innerHTML = '';
                [..._dpKnownBuffers.keys()].sort().forEach(value => {
                    const opt = document.createElement('option'); opt.value = value; dlBuf.appendChild(opt);
                });
            }
        }
    }
    const _refreshDl = (id, set) => {
        const dl = document.getElementById(id);
        if (!dl) return;
        const existing = new Set([...dl.options].map(o => o.value));
        [...set].filter(v => !existing.has(v)).sort().forEach(v => {
            const opt = document.createElement('option'); opt.value = v; dl.appendChild(opt);
        });
    };
    _refreshDl('dp-dl-stations', _dpKnownStations);
    _refreshDl('dp-dl-trains',   _dpKnownTrains);
}

function renderDispatch(dispatch, routesConfig) {
    // Badges config/safeMode — mis à jour sur les deux vues LIVE / updated on both LIVE views
    const cfgTxt = dispatch && dispatch.configOk ? 'Config OK' : (dispatch ? 'Config manquante' : 'LOGGER hors ligne');
    const cfgCls = dispatch && dispatch.configOk ? 'dp-badge ok' : 'dp-badge err';
    const badgeCfg  = document.getElementById('dp-badge-config');
    const badgeSafe = document.getElementById('dp-badge-safe');
    if (badgeCfg)  { badgeCfg.textContent = cfgTxt; badgeCfg.className = cfgCls; }
    if (badgeSafe) {
        if (dispatch && dispatch.safeMode) { badgeSafe.style.display = ''; badgeSafe.className = 'dp-badge warn'; badgeSafe.textContent = 'SAFE MODE'; }
        else { badgeSafe.style.display = 'none'; }
    }
    // Live routes depuis DISPATCH
    _dpOnline     = !!(dispatch && dispatch.configOk);
    _dpLiveRoutes = (dispatch && dispatch.routes && dispatch.routes.length > 0) ? dispatch.routes : null;
    // Ne pas toucher la config ni re-rendre si éditeur ouvert (évite d'écraser les saisies en cours)
    // Do not update config or re-render if editor is open (prevents overwriting in-progress edits)
    if (_dpEditingIndex >= 0) return;
    // Ne pas écraser la config si dp2 a une sélection active (évite de perdre les modifs en cours)
    // Don't overwrite config if dp2 has an active selection (avoids losing in-progress edits)
    if (_dp2SelectedIndex < 0) {
        if (Array.isArray(routesConfig) && (routesConfig.length > 0 || _dpRoutesConfig.length === 0)) {
            _dpRoutesConfig = routesConfig;
        }
    }
    // Mise à jour live si actif / Update live if active
    if (_lastDispatchPage === 'page-dispatch-live2') _dp2RenderLive();
}

function renderDpRoutes() {
    const container = document.getElementById('dp-routes');
    if (!container) return;
    container.innerHTML = '';
    // Bannière hors-ligne / Offline banner
    if (!_dpOnline) {
        const msg = _dpRoutesConfig.length > 0
            ? 'Serveur Satisfactory hors-ligne — données en attente de reconnexion. Les routes ci-dessous sont conservées depuis la dernière session.'
            : 'En attente de connexion au serveur Satisfactory…';
        container.insertAdjacentHTML('beforeend',
            `<div class="dp-offline-banner">${msg}</div>`);
        if (_dpRoutesConfig.length === 0) return;
    }
    if (_dpRoutesConfig.length === 0) {
        container.insertAdjacentHTML('beforeend',
            '<div style="color:#555;padding:20px 14px;font-size:0.82em;text-align:center">Aucune route configurée — cliquez sur + Route</div>');
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

// ── DISPATCH 2 — Configurateur deux panneaux ──────────────────
let _dp2SelectedIndex = -1;

function _dp2RenderList() {
    const listEl = document.getElementById('dp2-list');
    if (!listEl) return;
    let html = `<div class="dp2-list-header">
        <span class="dp2-list-title">ROUTES <span class="dp2-cnt">${_dpRoutesConfig.length}</span></span>
        <button class="dp-btn" onclick="dp2NewRoute()">+ Route</button>
    </div><div class="dp2-route-list">`;
    if (_dpRoutesConfig.length === 0) {
        html += `<div class="dp2-empty">Aucune route —<br>cliquez sur + Route</div>`;
    } else {
        _dpRoutesConfig.forEach((r, i) => {
            const live     = _dpLiveRoutes && _dpLiveRoutes.find(lr => lr.name === r.name);
            const sel      = _dp2SelectedIndex === i;
            const enabled  = r.enabled !== false;
            const liveBadge = live
                ? `<span class="dp-badge ok" style="font-size:0.65em;padding:1px 6px">● Live</span>`
                : `<span class="dp-badge warn" style="font-size:0.65em;padding:1px 6px">⏳</span>`;
            const disTag   = !enabled ? `<span class="dp2-off-tag">OFF</span>` : '';
            html += `<div class="dp2-route-item${sel ? ' selected' : ''}" onclick="dp2SelectRoute(${i})">
                <div class="dp2-item-name">${esc(r.name || '(sans nom)')}</div>
                <div class="dp2-item-meta">${esc(r.park||'?')} → ${esc(r.delivery||'?')}</div>
                <div class="dp2-item-foot">${liveBadge}${disTag}</div>
            </div>`;
        });
    }
    html += '</div>';
    listEl.innerHTML = html;
}

function renderDispatch2() {
    _dp2RenderList();
    _dp2RenderForm();
}

function _dp2RenderForm() {
    const formEl = document.getElementById('dp2-form');
    if (!formEl) return;
    if (_dp2SelectedIndex < 0 || _dp2SelectedIndex >= _dpRoutesConfig.length) {
        formEl.innerHTML = `<div class="dp2-form-placeholder">Sélectionner une route à gauche<br>ou créer une nouvelle route</div>`;
        return;
    }
    const r = _dpRoutesConfig[_dp2SelectedIndex];
    const enabled = r.enabled !== false;
    formEl.innerHTML = `
        <div class="dp2-form-header">
            <span class="dp2-form-title">ROUTE : ${esc(r.name || '(sans nom)')}</span>
        </div>
        <div class="dp2-form-body">
            <div class="dp-edit-field">
                <label>Nom</label>
                <input class="dp-input dp2-input" id="dp2-f-name" value="${esc(r.name||'')}">
            </div>
            <div class="dp-edit-field">
                <label>PARK</label>
                <input class="dp-input dp2-input" id="dp2-f-park" value="${esc(r.park||'')}" list="dp-dl-stations">
            </div>
            <div class="dp-edit-field">
                <label>DELIVERY</label>
                <input class="dp-input dp2-input" id="dp2-f-delivery" value="${esc(r.delivery||'')}" list="dp-dl-stations">
            </div>
            <div class="dp-edit-field">
                <label>Buffer</label>
                <input class="dp-input dp2-input" id="dp2-f-buffer" value="${esc(r.buffer||'')}" list="dp-dl-buffers">
            </div>
            <div class="dp-edit-field">
                <label>Max en route</label>
                <input class="dp-input dp2-input dp2-input-short" id="dp2-f-max" type="number" min="1" max="10" value="${r.maxEnRoute||1}">
            </div>
            <div class="dp-edit-field">
                <label>Trains</label>
                <input class="dp-input dp2-input" id="dp2-f-trains" value="${esc((r.trains||[]).join(', '))}" placeholder="T1, T2, ..." list="dp-dl-trains">
            </div>
            <div class="dp2-enabled-row">
                <label class="dp2-toggle-label">
                    <input type="checkbox" id="dp2-f-enabled" ${enabled ? 'checked' : ''}>
                    Route activée
                </label>
            </div>
        </div>
        <div class="dp2-form-actions">
            <button class="dp-save-btn" onclick="dp2SaveRoute()">💾 Sauvegarder</button>
            <button class="dp-btn del" onclick="dp2DeleteRoute()">✕ Supprimer</button>
            <span id="dp2-save-status" style="font-size:0.75em;color:#888;margin-left:8px"></span>
        </div>`;
}

function dp2SelectRoute(i) {
    _dp2SelectedIndex = i;
    renderDispatch2();
}

function dp2NewRoute() {
    _dpRoutesConfig.push({ name:'', park:'', delivery:'', buffer:'', maxEnRoute:1, trains:[], enabled:true });
    _dp2SelectedIndex = _dpRoutesConfig.length - 1;
    renderDispatch2();
    setTimeout(() => { const el = document.getElementById('dp2-f-name'); if (el) el.focus(); }, 30);
}

function dp2SaveRoute() {
    const i = _dp2SelectedIndex;
    if (i < 0 || i >= _dpRoutesConfig.length) return;
    const r = _dpRoutesConfig[i];
    r.name       = (document.getElementById('dp2-f-name')?.value || '').trim();
    r.park       = (document.getElementById('dp2-f-park')?.value || '').trim();
    r.delivery   = (document.getElementById('dp2-f-delivery')?.value || '').trim();
    r.buffer     = (document.getElementById('dp2-f-buffer')?.value || '').trim();
    r.maxEnRoute = +(document.getElementById('dp2-f-max')?.value || 1);
    const trainsRaw = (document.getElementById('dp2-f-trains')?.value || '').trim();
    r.trains     = trainsRaw ? trainsRaw.split(',').map(s => s.trim()).filter(s => s) : [];
    r.enabled    = !!(document.getElementById('dp2-f-enabled')?.checked);
    _dp2RenderList();
    _dp2SaveConfig();
}

function dp2DeleteRoute() {
    const i = _dp2SelectedIndex;
    if (i < 0) return;
    if (!confirm(`Supprimer la route "${_dpRoutesConfig[i].name||'(sans nom)'}" ?`)) return;
    _dpRoutesConfig.splice(i, 1);
    _dp2SelectedIndex = _dpRoutesConfig.length > 0 ? Math.min(i, _dpRoutesConfig.length - 1) : -1;
    renderDispatch2();
    _dp2SaveConfig();
}

function dp2ToggleEnabled(i) {
    if (i < 0 || i >= _dpRoutesConfig.length) return;
    _dpRoutesConfig[i].enabled = !(_dpRoutesConfig[i].enabled !== false);
    _dp2RenderLive();
    _dp2SaveConfig();
}

async function _dp2SaveConfig() {
    // Sauvegarde directe sans guard hasContent — gère aussi tableaux vides (delete all)
    // Direct save without hasContent guard — handles empty arrays too (delete all)
    const st = document.getElementById('dp2-save-status');
    if (st) st.textContent = 'Sauvegarde...';
    try {
        const resp = await fetch('/api/dispatch/routes', {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(_dpRoutesConfig),
        });
        const d = await resp.json();
        if (st) st.textContent = d.status === 'ok' ? `✓ ${d.count} route(s)` : '✗ Erreur serveur';
        setTimeout(() => { const s = document.getElementById('dp2-save-status'); if (s) s.textContent = ''; }, 3000);
        if (d.status === 'ok') setTimeout(() => sendDispatchCmd('reload', null, null), 800);
    } catch(e) {
        if (st) st.textContent = '✗ Erreur réseau';
    }
}

// ── DISPATCH LIVE 2 — vue cards ──────────────────────────────
function _dp2RenderLive() {
    const el = document.getElementById('dp2-live-grid');
    if (!el) return;
    if (_dpRoutesConfig.length === 0) {
        el.innerHTML = '<div style="color:#444;font-size:0.82em;padding:20px">Aucune route configurée.</div>';
        return;
    }
    el.innerHTML = _dpRoutesConfig.map((r, i) => {
        const live    = _dpLiveRoutes && _dpLiveRoutes.find(lr => lr.name === r.name);
        const enabled = r.enabled !== false;
        const badge   = live
            ? `<span class="dp-badge ok" style="font-size:0.65em;padding:1px 7px">● Live</span>`
            : `<span class="dp-badge warn" style="font-size:0.65em;padding:1px 7px">⏳</span>`;
        const toggleBtn = `<button class="dp2c-toggle ${enabled ? 'on' : 'off'}" onclick="dp2ToggleEnabled(${i})">${enabled ? 'ON' : 'OFF'}</button>`;

        let statsHtml = '';
        if (live) {
            const enRoute = live.enRoute || 0;
            const max     = live.maxEnRoute || r.maxEnRoute || 1;
            const pct     = Math.round(enRoute / max * 100);
            const barCls  = enRoute >= max ? 'full' : enRoute > 0 ? 'partial' : '';
            statsHtml = `
            <div class="dp2c-stats">
                <div class="dp2c-stat"><span class="dp2c-sl">ETA</span> <span class="dp2c-sv">${Math.round(live.eta?.avg||0)}s <span style="color:#555">±${Math.round(live.eta?.sigma||0)}s</span></span></div>
                <div class="dp2c-stat"><span class="dp2c-sl">buf</span> <span class="dp2c-sv">${live.buffer?.items||0}</span> <span class="dp2c-sl">drain</span> <span class="dp2c-sv">${(live.buffer?.drain||0).toFixed(2)}/s</span></div>
                <div class="dp2c-stat dp2c-enroute">
                    <span class="dp2c-sl">en route</span>
                    <span class="dp2c-sv ${barCls}">${enRoute}/${max}</span>
                    <div class="dp2c-bar-bg"><div class="dp2c-bar ${barCls}" style="width:${pct}%"></div></div>
                </div>
            </div>`;
        } else {
            statsHtml = `<div class="dp2c-offline-meta">${esc(r.park||'?')} → ${esc(r.delivery||'?')}<br><span style="color:#3a3a3a">buf: ${esc(r.buffer||'?')}</span></div>`;
        }

        const trainsHtml = live ? toArr(live.trains).map(st => {
            const phase   = st.phase || '?';
            const pCls    = phase==='PARK'?'park':phase==='EN_ROUTE'?'route':phase==='DELIVERY'?'delivery':'unknown';
            const dec     = st.decision==='go'?'Go':st.decision==='hold'?'Hold':'Idle';
            const dCls    = st.decision==='go'?'dec-go':st.decision==='hold'?'dec-hold':'dec-idle';
            return `<div class="dp2c-train">
                <div class="dp2c-train-info">
                    <span class="dp2c-tname">${esc(st.name)}</span>
                    <span class="dp-train-phase ${pCls}" style="font-size:0.67em">${phase}</span>
                    <span class="dp-train-decision ${dCls}" style="font-size:0.7em">${dec}</span>
                </div>
                <div class="dp2c-train-btns">
                    <button class="dp-btn go"   onclick="sendDispatchCmd('force_go','${esc(st.name)}','${esc(r.name)}')">GO</button>
                    <button class="dp-btn hold" onclick="sendDispatchCmd('force_hold','${esc(st.name)}','${esc(r.name)}')">HOLD</button>
                    <button class="dp-btn rec"  title="Recovery — reprend la logique DISPATCH si le train est bloqué" onclick="sendDispatchCmd('recovery','${esc(st.name)}','${esc(r.name)}')">REC</button>
                </div>
            </div>`;
        }).join('') : '';

        return `<div class="dp2c-card">
            <div class="dp2c-header">
                <span class="dp2c-name">${esc(r.name||'(sans nom)')}</span>
                ${badge}${toggleBtn}
            </div>
            ${statsHtml}
            ${trainsHtml ? `<div class="dp2c-trains">${trainsHtml}</div>` : ''}
        </div>`;
    }).join('');
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
        const col = LOG_TAG_COLORS[e.tag]
            || (e.tag && e.tag.startsWith('SAT:') ? '#ff9419' : null)
            || (e.tag && e.tag.startsWith('FAC:') ? '#8080ff' : null)
            || '#888';
        const div = document.createElement('div');
        div.style.cssText = 'border-bottom:1px solid #181818;padding:2px 0';
        div.innerHTML = `<span style="color:#fff;margin-right:8px">${e.ts}</span>`
            + `<span style="color:${col};font-weight:700;min-width:100px;display:inline-block" title="${e.tag}">${e.tag.slice(0,17)}</span> `
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

// ── USINE — modal détail / detail modal ──────────────────────
let _facDetailGroups = [];  // groupes stockés pour le modal / groups stored for modal
function _facShortClass(cls) { return (cls || '').replace(/^Build_/, '').replace(/Mk\d+_C$/, '').replace(/_C$/, ''); }

// Rendu carte machine dans le modal (utilise _facByNick) / Machine card in modal (uses _facByNick)
function _facModalMachineHtml(m) {
    if (!m) return '';
    const prod      = m.productivity ?? 0;
    const prodColor = prod >= 80 ? '#99ff00' : prod >= 50 ? '#ffcc00' : '#ff4444';
    const dimClass  = !m.active ? 'fac-machine-dim' : '';
    const inTotal   = (m.inputItems  || []).reduce((s, i) => s + (i.count || 0), 0);
    const outTotal  = (m.outputItems || []).reduce((s, i) => s + (i.count || 0), 0);
    return `<div class="fac-machine ${dimClass}" style="margin-bottom:5px">
        <div class="fac-machine-top">
            <span class="fac-machine-nick" title="${esc(m.nick)}">${esc(_facShortClass(m.class))}</span>
            <span class="fac-machine-class">(${esc(m.nick)})</span>
            <span style="color:${prodColor};font-size:0.75em;font-weight:700;margin-left:auto">${prod.toFixed(0)}%</span>
        </div>
        <div class="fac-prod-bar-bg"><div class="fac-prod-bar" style="width:${Math.min(prod,100)}%;background:${prodColor}"></div></div>
        <div class="fac-machine-bottom">
            <span title="Inventaire entrée"><img src="/static/img/IN.png" class="fac-icon"> ${inTotal}</span>
            <span title="Inventaire sortie"><img src="/static/img/OUT.png" class="fac-icon"> ${outTotal}</span>
            <span title="Puissance"><img src="/static/img/POWER.png" class="fac-icon"> ${(m.power ?? 0).toFixed(1)} MW</span>
            ${m.cycleTime ? `<span title="Durée cycle">⏱ ${m.cycleTime.toFixed(1)}s</span>` : ''}
            ${m.potential != null && m.potential !== 100 ? `<span title="Overclock" style="color:#ffaa00">${m.potential.toFixed(0)}%⚡</span>` : ''}
        </div>
    </div>`;
}

function openFacDetail(idx) {
    const g = _facDetailGroups[idx];
    if (!g) return;
    const modal = document.getElementById('fac-detail-modal');
    const title = document.getElementById('fac-detail-title');
    const body  = document.getElementById('fac-detail-body');
    if (!modal) return;
    title.textContent = g.name || 'Zone';

    // Rendu d'un groupe de nicks avec header optionnel / Render a nick group with optional header
    function sectionBlock(headerName, nicks) {
        if (!nicks || !nicks.length) return '';
        const header = headerName
            ? `<div class="fac-detail-section-title">${esc(headerName)}</div>`
            : '';
        const cards = nicks.map(n => _facModalMachineHtml(_facByNick[n])).join('');
        return header + `<div class="fac-machine-list">${cards}</div>`;
    }

    let html = '';
    // Machines directes de la zone / Direct zone machines
    html += sectionBlock(g.mainLabel || null, g.directNicks || []);
    // Sous-zones / Subzones
    for (const sz of (g.subzones || [])) {
        html += sectionBlock(sz.name, sz.machines || []);
    }

    body.innerHTML = html || '<div style="color:#666;font-size:0.85em">Aucune machine</div>';
    modal.classList.add('open');
}

function closeFacDetail() {
    const modal = document.getElementById('fac-detail-modal');
    if (modal) modal.classList.remove('open');
}

// ── USINE — toggle vue compacte/détaillée ─────────────────────
function toggleFacView() {
    _facCompact = !_facCompact;
    const btn = document.getElementById('fac-view-btn');
    if (btn) btn.textContent = _facCompact ? 'Vue détaillée' : 'Vue compacte';
    if (_lastFactoryData) renderFactory(_lastFactoryData);
}

// ── USINE — purge des machines absentes des satellites ─────────
function purgeFacInactifs() {
    if (!_lastFactoryData || !_factoryZoneConfig.zones.length) return;
    const btn = document.querySelector('#page-usine-info .stock-purge-btn:last-child');
    if (btn) { btn.disabled = true; btn.textContent = '...'; }
    // Nicks connus dans les satellites / Known nicks from satellites
    const known = new Set();
    for (const z of (_lastFactoryData.zones || [])) for (const m of (z.machines || [])) known.add(m.nick);
    // Retirer les nicks absents / Remove absent nicks
    let removed = 0;
    for (const z of _factoryZoneConfig.zones) {
        const before = z.machines.length;
        z.machines = z.machines.filter(n => known.has(n));
        removed += before - z.machines.length;
        for (const sz of (z.subzones || [])) {
            const sbefore = sz.machines.length;
            sz.machines = sz.machines.filter(n => known.has(n));
            removed += sbefore - sz.machines.length;
        }
    }
    if (btn) { btn.textContent = removed > 0 ? `${removed} supprimé(s)` : 'Rien à purger'; }
    setTimeout(() => { if (btn) { btn.disabled = false; btn.textContent = 'Purger les inactifs'; } }, 2500);
    if (removed > 0) {
        fetch('/api/factory/zone-config', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(_factoryZoneConfig) })
            .then(() => { _prevJson.factory = null; setTimeout(() => renderFactory(_lastFactoryData), 0); });
    }
}

// ── USINE — rendu machines de production ─────────────────────
function renderFactory(fac) {
    const grid = document.getElementById('fac-grid');
    if (!grid) return;

    const totalActiveEl = document.getElementById('fac-total-active');
    const totalCntEl    = document.getElementById('fac-total-cnt');
    const totalPowerEl  = document.getElementById('fac-total-power');
    const zoneCountEl   = document.getElementById('fac-zone-count');
    const staleEl       = document.getElementById('fac-stale');

    if (!fac || !fac.zones || fac.zones.length === 0) {
        if (totalActiveEl) totalActiveEl.textContent = '—';
        if (totalCntEl)    totalCntEl.textContent    = '—';
        if (totalPowerEl)  totalPowerEl.textContent  = '—';
        if (zoneCountEl)   zoneCountEl.textContent   = '';
        if (staleEl)       staleEl.textContent       = '';
        grid.innerHTML = '<div style="color:#888;padding:20px;font-size:0.85em">En attente des données FACTORY_CENTRAL…</div>';
        return;
    }

    if (totalActiveEl) totalActiveEl.textContent = fac.activeMachines ?? '—';
    if (totalCntEl)    totalCntEl.textContent    = fac.totalMachines  ?? '—';
    if (totalPowerEl)  totalPowerEl.textContent  = (fac.totalPower != null ? fac.totalPower.toFixed(1) + ' MW' : '—');

    const ageSec = fac.server_ts ? Math.round(Date.now() / 1000 - fac.server_ts) : null;
    if (staleEl) staleEl.textContent = ageSec != null && ageSec > 60 ? `Dernière MAJ: ${ageSec}s` : '';

    // Lookup machine par nick / Machine lookup by nick
    const byNick = {};
    for (const z of fac.zones) for (const m of (z.machines || [])) {
        // Normaliser inputItems/outputItems en array (le satellite peut envoyer {} si vide)
        // Normalize inputItems/outputItems to array (satellite may send {} when empty)
        if (!Array.isArray(m.inputItems))  m.inputItems  = [];
        if (!Array.isArray(m.outputItems)) m.outputItems = [];
        byNick[m.nick] = m;
    }
    _facByNick = byNick;  // exposer pour le modal / expose for modal

    // Groupe les machines par recette — OFF séparé / Group machines by recipe — OFF separate
    function groupByRecipe(nicks) {
        const recipeMap = {};  // recipe → [machine, ...]
        const offList   = [];
        for (const n of nicks) {
            const m = byNick[n];
            if (!m) continue;
            if (!m.active || !m.recipe) { offList.push(m); continue; }
            if (!recipeMap[m.recipe]) recipeMap[m.recipe] = [];
            recipeMap[m.recipe].push(m);
        }
        return { recipeMap, offList };
    }

    // Rendu d'un groupe de recette (visuel seul, pas de onclick) / Recipe group (visual only, no onclick)
    function recipeGroupHtml(recipe, machines) {
        const totalPow   = machines.reduce((s, m) => s + (m.power ?? 0), 0);
        const inTotal    = machines.reduce((s, m) => s + (m.inputItems  || []).reduce((a, i) => a + (i.count || 0), 0), 0);
        const outTotal   = machines.reduce((s, m) => s + (m.outputItems || []).reduce((a, i) => a + (i.count || 0), 0), 0);

        // Somme des ingrédients consommés (quantité × nb machines) / Sum of ingredients consumed (qty × machine count)
        const ingMap = {};
        machines.forEach(m => {
            (m.ingredients || []).forEach(ing => {
                ingMap[ing.name] = (ingMap[ing.name] || 0) + (ing.amount || 0);
            });
        });
        const ingHtml = Object.entries(ingMap)
            .map(([n, a]) => `<span class="fac-ing">${esc(n.replace(/^Desc_|_C$/g, ''))}: ${a}</span>`)
            .join('');

        return `<div class="fac-recipe-group">
            <div class="fac-card-header">
                <span class="fac-recipe-name">${esc(recipe)}</span>
            </div>
            ${ingHtml ? `<div class="fac-ing-list">${ingHtml}</div>` : ''}
            <div class="fac-card-meta">${machines.length} mach. &nbsp;·&nbsp; <img src="/static/img/IN.png" class="fac-icon"> ${inTotal} &nbsp;·&nbsp; <img src="/static/img/OUT.png" class="fac-icon"> ${outTotal} &nbsp;·&nbsp; <img src="/static/img/POWER.png" class="fac-icon"> ${totalPow.toFixed(1)} MW</div>
        </div>`;
    }

    // Rendu machines OFF (visuel seul) / OFF machines (visual only)
    function offGroupHtml(offList) {
        if (!offList.length) return '';
        return `<div class="fac-recipe-group fac-recipe-off">
            <div class="fac-recipe-header">
                <span class="fac-recipe-name" style="color:#666">Sans recette / Standby</span>
                <span class="fac-recipe-count">${offList.length} mach.</span>
                <span class="fac-off-badge">OFF</span>
            </div>
        </div>`;
    }

    // Rendu d'une section de machines (zone ou sous-zone) / Section renderer (zone or subzone)
    // Rendu vue détaillée — machine individuelle / Detailed view — individual machine card
    function machineCardHtml(m) {
        const prod      = m.productivity ?? 0;
        const prodColor = prod >= 80 ? '#99ff00' : prod >= 50 ? '#ffcc00' : '#ff4444';
        const dimClass  = !m.active ? 'fac-machine-dim' : '';
        const inTotal   = (m.inputItems  || []).reduce((s, i) => s + (i.count || 0), 0);
        const outTotal  = (m.outputItems || []).reduce((s, i) => s + (i.count || 0), 0);
        return `<div class="fac-machine ${dimClass}">
            <div class="fac-machine-top">
                <span class="fac-machine-nick" title="${esc(m.nick)}">${esc(_facShortClass(m.class))}</span>
                <span class="fac-machine-class">(${esc(m.nick)})</span>
                <span style="color:${prodColor};font-size:0.75em;font-weight:700;margin-left:auto">${prod.toFixed(0)}%</span>
            </div>
            <div class="fac-prod-bar-bg"><div class="fac-prod-bar" style="width:${Math.min(prod,100)}%;background:${prodColor}"></div></div>
            <div class="fac-machine-bottom">
                <span title="Inventaire entrée"><img src="/static/img/IN.png" class="fac-icon"> ${inTotal}</span>
                <span title="Inventaire sortie"><img src="/static/img/OUT.png" class="fac-icon"> ${outTotal}</span>
                <span title="Puissance"><img src="/static/img/POWER.png" class="fac-icon"> ${(m.power ?? 0).toFixed(1)} MW</span>
                ${m.cycleTime ? `<span title="Durée cycle">⏱ ${m.cycleTime.toFixed(1)}s</span>` : ''}
                ${m.recipe ? `<span class="fac-machine-recipe" style="margin-left:auto">${esc(m.recipe)}</span>` : ''}
            </div>
        </div>`;
    }

    function sectionHtml(nicks, stale) {
        if (stale) {
            return nicks.map(n => byNick[n]).filter(Boolean).map(m =>
                `<div class="fac-recipe-group fac-recipe-off">
                    <div class="fac-recipe-header">
                        <span class="fac-recipe-name" style="color:#555">${esc(m.nick)}</span>
                        <span class="fac-off-badge">HORS LIGNE</span>
                    </div>
                </div>`
            ).join('');
        }
        if (!_facCompact) {
            // Vue détaillée : machines individuelles / Detailed view: individual machines
            const machines = nicks.map(n => byNick[n]).filter(Boolean);
            return `<div class="fac-machine-list">${machines.map(machineCardHtml).join('')}</div>`;
        }
        const { recipeMap, offList } = groupByRecipe(nicks);
        const recipeHtml = Object.keys(recipeMap).sort().map(r => recipeGroupHtml(r, recipeMap[r])).join('');
        return recipeHtml + offGroupHtml(offList);
    }

    // Stats zone — retourne objet / Zone stats — returns object
    function zoneStats(nicks) {
        let active = 0, total = 0, prodSum = 0, pow = 0;
        for (const n of nicks) {
            const m = byNick[n]; if (!m) continue;
            total++;
            if (m.active && m.recipe) { active++; prodSum += m.productivity ?? 0; pow += m.power ?? 0; }
        }
        const avg   = active > 0 ? Math.round(prodSum / active) : 0;
        const color = avg >= 80 ? '#99ff00' : avg >= 50 ? '#ffcc00' : total > 0 ? '#ff4444' : '#666';
        return { avg, active, total, pow, color };
    }

    // HTML section sous-zone (nom + barre petite + recettes) / Subzone HTML (name + small bar + recipes)
    function subzoneHtml(name, nicks) {
        const st = zoneStats(nicks);
        return `<div class="fac-subzone-info">
            <div class="fac-subzone-info-header">
                <span class="fac-subzone-info-name">${esc(name)}</span>
                <span class="fac-sz-pct" style="color:${st.color}">${st.avg}%</span>
            </div>
            <div class="fac-sz-bar-bg"><div class="fac-sz-bar" style="width:${Math.min(st.avg,100)}%;background:${st.color}"></div></div>
            <div class="fac-recipe-list">${sectionHtml(nicks, false)}</div>
        </div>`;
    }

    // HTML card zone principale / Main zone card
    // showBar=true → barre sous le titre (pas de sous-zones) / bar under title (no subzones)
    // showBar=false → % seul dans le titre, barre dans chaque sous-zone / % only in title, bar per subzone
    function zoneCardHtml(name, allNicks, zoneIdx, staleTag, showBar, content) {
        const st  = zoneStats(allNicks);
        const bar = showBar ? `<div class="fac-bar-bg"><div class="fac-bar" style="width:${Math.min(st.avg,100)}%;background:${st.color}"></div></div>
            <div class="fac-card-meta">${st.active}/${st.total} actives &nbsp;·&nbsp; <img src="/static/img/POWER.png" class="fac-icon"> ${st.pow.toFixed(1)} MW</div>` : '';
        return `<div class="fac-zone" onclick="openFacDetail(${zoneIdx})" title="Voir toutes les machines" style="cursor:pointer">
            <div class="fac-card-header">
                <span class="fac-zone-name">${esc(name)}${staleTag}</span>
                <span class="fac-card-pct" style="color:${st.color}">${st.avg}%</span>
            </div>
            ${bar}${content}
        </div>`;
    }

    _facDetailGroups = [];  // reset à chaque render / reset on each render

    const cfgZones = _factoryZoneConfig && _factoryZoneConfig.zones;

    if (cfgZones && cfgZones.length) {
        if (zoneCountEl) zoneCountEl.textContent = cfgZones.length + ' zone' + (cfgZones.length > 1 ? 's' : '');
        grid.innerHTML = cfgZones.map(zone => {
            const allNicks = [...(zone.machines || []), ...((zone.subzones || []).flatMap(sz => sz.machines || []))];
            const zoneIdx  = _facDetailGroups.length;
            _facDetailGroups.push({ name: zone.name, directNicks, mainLabel, subzones: hasSubs ? zone.subzones : [] });

            const directNicks = zone.machines || [];
            const hasSubs     = zone.subzones && zone.subzones.length;
            const mainLabel   = zone.mainLabel && hasSubs ? zone.mainLabel : null;
            const directHtml  = directNicks.length
                ? (mainLabel ? subzoneHtml(mainLabel, directNicks) : `<div class="fac-recipe-list">${sectionHtml(directNicks, false)}</div>`)
                : '';
            const subzonesHtml = hasSubs ? zone.subzones.map(sz => subzoneHtml(sz.name, sz.machines || [])).join('') : '';

            const showBar = !hasSubs;
            return zoneCardHtml(zone.name, allNicks, zoneIdx, '', showBar, directHtml + subzonesHtml);
        }).join('');
    } else {
        // Fallback par satellite / Fallback by satellite
        if (zoneCountEl) zoneCountEl.textContent = fac.zones.length + ' sat.';
        grid.innerHTML = fac.zones.map(zone => {
            const nicks   = (zone.machines || []).map(m => m.nick);
            const zoneIdx = _facDetailGroups.length;
            _facDetailGroups.push({ name: zone.name, directNicks: nicks, mainLabel: null, subzones: [] });
            const staleTag = zone.stale ? ' <span class="fac-stale">HORS LIGNE</span>' : '';
            return zoneCardHtml(zone.name, nicks, zoneIdx, staleTag, true, `<div class="fac-recipe-list">${sectionHtml(nicks, !!zone.stale)}</div>`);
        }).join('');
    }
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
