__version__ = "1.0.7"

"""
train_server.py : serveur web + bot Discord pour Train Monitor — Satisfactory
- Flask  : dashboard web sur le port 8081
- Discord: embed édité toutes les X secondes dans un canal (pas de notification)

Lancer : python train_server.py
Config  : renseigner config.py (token, channel_id)
"""

from flask import Flask, jsonify, send_from_directory, request
import json, os, threading, time, logging
from datetime import datetime, timezone

import discord
import asyncio

import config

# ── Cache partagé (Flask + Discord lisent le même) ───────────
# Alimenté par POST /api/push depuis LOGGER via InternetCard
_cache            = {"trains": [], "trips": {}}
_cache_updated_at = 0.0   # timestamp (epoch) du dernier push reçu de LOGGER
_trips            = {}    # historique de la session courante (en mémoire uniquement — pas de persistence)
_stats            = {}    # stats calculées par LOGGER (score, conf, avgSpeed, etc.)
_stockage         = {}    # données stockage par zone (LOGGER → /api/push) : {zone: {...}}
_stockage_central   = {}  # données CENTRAL agrégées (CENTRAL → /api/stockage/push)
_stockage_discovery = {}  # satellites découverts : {nick: {satellite, addr, containers, server_ts}}

_ORDER_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "stockage_order.json")
def _load_order():
    try:
        with open(_ORDER_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return []
def _save_order(order):
    try:
        with open(_ORDER_FILE, "w", encoding="utf-8") as f:
            json.dump(order, f)
    except Exception:
        pass
_stockage_order = _load_order()

# ── Zone config stockage (persistée dans stockage_zone_config.json) ────────
_STOCKAGE_ZONE_CONFIG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "stockage_zone_config.json")
def _load_zone_config():
    try:
        with open(_STOCKAGE_ZONE_CONFIG_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {"zones": []}
def _save_zone_config(cfg):
    try:
        with open(_STOCKAGE_ZONE_CONFIG_FILE, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
    except Exception:
        pass
_stockage_zone_config = _load_zone_config()

# ── Dispatch routes (persistées dans dispatch_routes.json) ────
_DISPATCH_ROUTES_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dispatch_routes.json")

def _load_dispatch_routes():
    try:
        with open(_DISPATCH_ROUTES_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return []

def _save_dispatch_routes(routes):
    try:
        with open(_DISPATCH_ROUTES_FILE, "w", encoding="utf-8") as f:
            json.dump(routes, f, indent=2, ensure_ascii=False)
        return None
    except Exception as e:
        return str(e)

_dispatch_routes      = _load_dispatch_routes()
_dispatch_status      = {}    # état temps réel poussé par LOGGER (agrégé depuis DISPATCH port 69)
_dispatch_pending_cmd = None  # commande web en attente d'être consommée par LOGGER

# ── Persistance logs FIN sur disque / FIN log persistence ────
_LOG_DIR      = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs")
_LOG_FILE     = os.path.join(_LOG_DIR, "fin_logs.jsonl")
_LOG_TRIM_AT  = 200_000  # lignes max avant trim / max lines before trim
_LOG_TRIM_TO  = 100_000  # lignes conservées après trim / lines kept after trim
_log_lock     = __import__("threading").Lock()

def _load_logs_from_file(n=5000):
    """Charge les n dernières entrées du fichier JSONL / Load last n entries from JSONL file."""
    try:
        with open(_LOG_FILE, "r", encoding="utf-8") as f:
            lines = f.readlines()
        result = []
        for line in lines[-n:]:
            try: result.append(json.loads(line))
            except Exception: pass
        return result
    except FileNotFoundError:
        return []

def _append_logs_to_file(entries):
    """Append entries to JSONL file, trim if too large / Écriture incrémentale + trim si trop grand."""
    os.makedirs(_LOG_DIR, exist_ok=True)
    with _log_lock:
        with open(_LOG_FILE, "a", encoding="utf-8") as f:
            for e in entries:
                f.write(json.dumps(e, ensure_ascii=False) + "\n")
        # Trim si le fichier dépasse _LOG_TRIM_AT lignes / Trim when file exceeds limit
        try:
            with open(_LOG_FILE, "r", encoding="utf-8") as f:
                lines = f.readlines()
            if len(lines) > _LOG_TRIM_AT:
                with open(_LOG_FILE, "w", encoding="utf-8") as f:
                    f.writelines(lines[-_LOG_TRIM_TO:])
        except Exception:
            pass

_log_ring       = _load_logs_from_file(10_000) # historique chargé au démarrage / history loaded at startup
_LOG_RING_MAX   = 15_000                       # cap mémoire / memory cap
_log_total_ever = len(_log_ring)               # compteur absolu cumulatif — ne décroît jamais / absolute cumulative counter — never decreases

def _to_lua(obj):
    """Convertit un objet Python en chaîne table Lua (parseable par load('return '..s)() )."""
    if isinstance(obj, dict):
        parts = [f'{k}={_to_lua(v)}' for k, v in obj.items()]
        return '{' + ','.join(parts) + '}'
    elif isinstance(obj, list):
        parts = [_to_lua(item) for item in obj]
        return '{' + ','.join(parts) + '}'
    elif isinstance(obj, str):
        escaped = obj.replace('\\', '\\\\').replace('"', '\\"')
        return f'"{escaped}"'
    elif isinstance(obj, bool):
        return 'true' if obj else 'false'
    elif isinstance(obj, (int, float)):
        return str(obj)
    return 'nil'


# ════════════════════════════════════════════════════════════
# FLASK — dashboard web
# ════════════════════════════════════════════════════════════

app = Flask(__name__)


@app.route("/api/push", methods=["POST"])
def receive_push():
    """Reçoit le snapshot trains + trips + stats + stockage de LOGGER (toutes les 2s)."""
    global _cache, _cache_updated_at, _trips, _stats, _stockage, _log_ring, _log_total_ever
    body = request.get_json(silent=True)
    if not body:
        return jsonify({"error": "Body JSON manquant"}), 400
    _cache = body
    _cache_updated_at = time.time()
    if isinstance(body.get("trips"), dict) and body["trips"]:
        _trips = body["trips"]
    if isinstance(body.get("stats"), dict):
        _stats = body["stats"]
    if isinstance(body.get("stockage"), list):
        for zone in body["stockage"]:
            name = zone.get("zone") or "?"
            zone["server_ts"] = time.time()
            _stockage[name] = zone
    if isinstance(body.get("dispatch"), dict):
        _dispatch_status.update(body["dispatch"])
        _dispatch_status["server_ts"] = time.time()
    new_logs = body.get("logs") or []
    if new_logs:
        ts = datetime.now(timezone.utc).strftime("%d/%m %H:%M:%S")
        parsed = [{"ts": ts, "tag": str(e.get("tag", "?")), "msg": str(e.get("msg", ""))} for e in new_logs]
        _log_ring.extend(parsed)
        _log_total_ever += len(parsed)
        if len(_log_ring) > _LOG_RING_MAX:
            del _log_ring[:-_LOG_RING_MAX]
        _append_logs_to_file(parsed)
    return jsonify({"status": "ok"})


@app.route("/api/trips", methods=["POST"])
def receive_trips():
    """Reçoit l'historique complet des trajets (appelé immédiatement après chaque trajet)."""
    global _trips
    body = request.get_json(silent=True)
    if body is None:
        return jsonify({"error": "Body JSON manquant"}), 400
    _trips = body
    _cache["trips"] = _trips
    return jsonify({"status": "ok"})


@app.route("/api/stockage-order", methods=["POST"])
def set_stockage_order():
    global _stockage_order
    body = request.get_json(silent=True)
    if not isinstance(body, list):
        return jsonify({"error": "Liste attendue"}), 400
    _stockage_order = body
    _save_order(_stockage_order)
    return jsonify({"status": "ok"})


_STOCKAGE_TTL = 600  # secondes — zone non mise à jour depuis plus de 10 min → supprimée

@app.route("/api/stockage-purge", methods=["POST"])
def purge_stockage():
    """Supprime manuellement toutes les zones inactives (server_ts > 120s)."""
    global _stockage
    now = time.time()
    before = len(_stockage)
    _stockage = {k: v for k, v in _stockage.items() if (now - v.get("server_ts", 0)) <= 120}
    removed = before - len(_stockage)
    return jsonify({"status": "ok", "removed": removed})


@app.route("/api/stockage/push", methods=["POST"])
def stockage_central_push():
    """Reçoit les données agrégées de STOCKAGE_CENTRAL (toutes les 30s)."""
    global _stockage_central
    body = request.get_json(silent=True)
    if not body:
        return jsonify({"error": "Body JSON manquant"}), 400
    body["server_ts"] = time.time()
    _stockage_central = body
    return jsonify({"status": "ok"})


@app.route("/api/stockage/zone-config", methods=["GET"])
def get_zone_config():
    return jsonify(_stockage_zone_config)


@app.route("/api/stockage/zone-config", methods=["POST"])
def set_zone_config():
    global _stockage_zone_config
    body = request.get_json(silent=True)
    if not isinstance(body, dict) or "zones" not in body:
        return jsonify({"error": "Format invalide — {zones:[...]} attendu"}), 400
    _stockage_zone_config = body
    _save_zone_config(_stockage_zone_config)
    return jsonify({"status": "ok"})


@app.route("/api/stockage/discovery", methods=["POST"])
def stockage_discovery():
    """Reçoit la liste des containers découverts par un satellite."""
    global _stockage_discovery
    body = request.get_json(silent=True)
    if not body:
        return jsonify({"error": "Body JSON manquant"}), 400
    sat = body.get("satellite") or body.get("addr") or "?"
    _stockage_discovery[sat] = {
        "satellite":  sat,
        "addr":       body.get("addr", ""),
        "containers": body.get("containers", []),
        "server_ts":  time.time(),
    }
    return jsonify({"status": "ok"})


@app.route("/api/dispatch/routes", methods=["GET"])
def get_dispatch_routes():
    """Retourne la config des routes dispatch (JSON ou ?format=lua pour la web UI)."""
    if request.args.get("format") == "lua":
        return _to_lua(_dispatch_routes), 200, {"Content-Type": "text/plain"}
    return jsonify(_dispatch_routes)

@app.route("/api/dispatch/routes.lua", methods=["GET", "POST"])
def get_dispatch_routes_lua():
    """Config dispatch pour LOGGER — GET (debug/curl) ou POST (FIN InternetCard, GET non supporté)."""
    return _to_lua(_dispatch_routes), 200, {"Content-Type": "text/plain"}

@app.route("/api/dispatch/routes", methods=["PUT"])
def put_dispatch_routes():
    """Sauvegarde la config routes (depuis la web UI)."""
    global _dispatch_routes
    body = request.get_json(silent=True)
    if not isinstance(body, list):
        return jsonify({"error": "Liste de routes attendue"}), 400
    _dispatch_routes = body
    save_err = _save_dispatch_routes(_dispatch_routes)
    if save_err:
        return jsonify({"status": "ok", "count": len(_dispatch_routes), "save_warning": save_err})
    return jsonify({"status": "ok", "count": len(_dispatch_routes)})

@app.route("/api/dispatch/command", methods=["POST"])
def dispatch_command():
    """
    Reçoit une commande depuis la web UI → stockée, LOGGER la récupèrera
    au prochain poll et la transmettra à DISPATCH via net:send port 69.
    Body: { "cmd": "force_go"|"force_hold"|"recovery"|"reload", "train": "...", "route": "..." }
    """
    global _dispatch_pending_cmd
    body = request.get_json(silent=True)
    if not body or "cmd" not in body:
        return jsonify({"error": "cmd manquant"}), 400
    body["ts"] = time.time()
    _dispatch_pending_cmd = body
    return jsonify({"status": "queued", "cmd": body["cmd"]})

@app.route("/api/dispatch/command", methods=["GET"])
def get_dispatch_command():
    """LOGGER poll cette route pour récupérer la prochaine commande en attente.
    ?format=lua → retourne une table Lua (nil si aucune commande)."""
    global _dispatch_pending_cmd
    lua_mode = request.args.get("format") == "lua"
    if not _dispatch_pending_cmd:
        return ("nil", 200, {"Content-Type": "text/plain"}) if lua_mode else jsonify(None)
    cmd = _dispatch_pending_cmd
    _dispatch_pending_cmd = None   # consommée
    if lua_mode:
        return _to_lua(cmd), 200, {"Content-Type": "text/plain"}
    return jsonify(cmd)

@app.route("/api/dispatch/command.lua", methods=["GET", "POST"])
def get_dispatch_command_lua():
    """Endpoint dédié Lua pour LOGGER (InternetCard ne supporte pas les query strings)."""
    global _dispatch_pending_cmd
    if not _dispatch_pending_cmd:
        return "nil", 200, {"Content-Type": "text/plain"}
    cmd = _dispatch_pending_cmd
    _dispatch_pending_cmd = None
    return _to_lua(cmd), 200, {"Content-Type": "text/plain"}

@app.route("/api/fin/<path:script>", methods=["GET", "POST"])
def get_fin_script(script):
    """Sert les scripts FIN Lua depuis fin/ — utilisé par les EEPROM bootstrap."""
    fin_dir = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fin"))
    return send_from_directory(fin_dir, script, mimetype="text/plain")

@app.route("/api/data")
def get_data():
    # Auto-nettoyage TTL : zones sans update depuis > 10 min
    global _stockage
    now = time.time()
    _stockage = {k: v for k, v in _stockage.items() if (now - v.get("server_ts", 0)) <= _STOCKAGE_TTL}
    return jsonify({
        **_cache,
        "trips":           _trips,
        "stats":           _stats,
        "stockage":        list(_stockage.values()),
        "logger_updated_at": _cache_updated_at,
        "site_title":      getattr(config, "SITE_TITLE", "FN Monitor"),
        "stockage_order":  _stockage_order,
        "dispatch":             _dispatch_status,
        "dispatch_routes":      _dispatch_routes,
        "stockage_central":     _stockage_central or None,
        "stockage_discovery":   list(_stockage_discovery.values()),
        "stockage_zone_config": _stockage_zone_config,
    })


@app.route("/api/dispatch/report")
def get_dispatch_report():
    """Analyse les derniers logs DISPATCH et retourne un rapport structuré."""
    import re
    limit = min(int(request.args.get("limit", 300)), 2000)
    entries = _log_ring[-limit:]
    dispatch = [e for e in entries if e.get("tag") == "DISPATCH"]

    period_from = entries[0]["ts"]  if entries  else "—"
    period_to   = entries[-1]["ts"] if entries  else "—"

    issues = []

    # GO avec wagon=0 — trajet à vide (inutile)
    go_empty = [e for e in dispatch if " GO " in e["msg"] and "wagon=0" in e["msg"]]
    if go_empty:
        issues.append({
            "type": "go_wagon_vide",
            "severity": "high",
            "label": "GO avec wagon vide (wagon=0)",
            "count": len(go_empty),
            "entries": [{"ts": e["ts"], "msg": e["msg"]} for e in go_empty[-5:]],
        })

    # buf=0 permanent (bug parsing ou buffer vraiment vide)
    buf0_cycles = [e for e in dispatch if "buf=0(" in e["msg"]]
    if len(buf0_cycles) >= 3:
        issues.append({
            "type": "buf_zero_permanent",
            "severity": "high",
            "label": "Buffer toujours à 0 (bug parsing ?)",
            "count": len(buf0_cycles),
            "entries": [{"ts": e["ts"], "msg": e["msg"]} for e in buf0_cycles[-3:]],
        })

    # GO URGENCE
    go_urgence = [e for e in dispatch if " GO " in e["msg"] and "URGENCE" in e["msg"]]
    if go_urgence:
        issues.append({
            "type": "go_urgence",
            "severity": "medium",
            "label": "GO en URGENCE (slots ≤ MIN_BUF_SLOTS)",
            "count": len(go_urgence),
            "entries": [{"ts": e["ts"], "msg": e["msg"]} for e in go_urgence[-5:]],
        })

    # GO avec buf > 500 (livraison potentiellement inutile)
    go_high_buf = []
    for e in dispatch:
        if " GO " in e["msg"]:
            m = re.search(r"buf=(\d+)", e["msg"])
            if m and int(m.group(1)) > 500:
                go_high_buf.append(e)
    if go_high_buf:
        issues.append({
            "type": "go_buf_eleve",
            "severity": "low",
            "label": "GO alors que buf > 500 items",
            "count": len(go_high_buf),
            "entries": [{"ts": e["ts"], "msg": e["msg"]} for e in go_high_buf[-5:]],
        })

    # TIMEOUT
    timeouts = [e for e in dispatch if "TIMEOUT" in e["msg"]]
    if timeouts:
        issues.append({
            "type": "timeout",
            "severity": "medium",
            "label": "TIMEOUT déclenché (wagon sous-chargé trop longtemps)",
            "count": len(timeouts),
            "entries": [{"ts": e["ts"], "msg": e["msg"]} for e in timeouts[-5:]],
        })

    # Trains boucle (> 2 GO dans la fenêtre)
    from collections import defaultdict
    go_counts = defaultdict(list)
    for e in dispatch:
        m = re.match(r"(.+?) GO \[", e["msg"])
        if m:
            go_counts[m.group(1).strip()].append(e)
    loopers = {k: v for k, v in go_counts.items() if len(v) > 2}
    if loopers:
        entries_list = []
        for train, evts in sorted(loopers.items(), key=lambda x: -len(x[1])):
            entries_list.append({"ts": evts[-1]["ts"], "msg": f"{train} : {len(evts)}x GO dans la fenêtre"})
        issues.append({
            "type": "boucle",
            "severity": "medium",
            "label": "Train(s) faisant de nombreux allers-retours",
            "count": len(loopers),
            "entries": entries_list,
        })

    # WARN / introuvable
    warns = [e for e in dispatch if "WARN" in e["msg"] or "introuvable" in e["msg"]]
    if warns:
        issues.append({
            "type": "warn",
            "severity": "low",
            "label": "Avertissements DISPATCH",
            "count": len(warns),
            "entries": [{"ts": e["ts"], "msg": e["msg"]} for e in warns[-5:]],
        })

    # Dernières décisions par route — HOLD depuis log status, GO depuis log transition
    last_decisions = {}
    for e in dispatch:
        # HOLD : "[ROUTE/attente] ... -> HOLD (reason)"
        m = re.match(r"\[([^\]]+)/\w+\].*(-> (GO|HOLD).*)", e["msg"])
        if m:
            route = m.group(1)
            last_decisions[route] = {"ts": e["ts"], "msg": e["msg"], "verdict": m.group(3)}
        else:
            # GO transition : "TRAIN_NAME GO [PARK->DELIVERY] buf=..."
            m2 = re.search(r"GO \[([^\]]+)\]", e["msg"])
            if m2 and " GO " in e["msg"]:
                # extraire le nom de route depuis buf= et reconstruire depuis last_decisions existant
                # utiliser la destination comme clé approximative
                route = m2.group(1)
                last_decisions[route] = {"ts": e["ts"], "msg": e["msg"], "verdict": "GO"}

    high_count   = sum(1 for i in issues if i["severity"] == "high")
    medium_count = sum(1 for i in issues if i["severity"] == "medium")
    healthy      = (high_count == 0 and medium_count == 0)

    return jsonify({
        "period":         {"from": period_from, "to": period_to},
        "total_analyzed": len(entries),
        "dispatch_count": len(dispatch),
        "issues":         issues,
        "last_decisions": list(last_decisions.values()),
        "healthy":        healthy,
        "high_count":     high_count,
        "medium_count":   medium_count,
    })


@app.route("/api/perf/trains")
def get_perf_trains():
    """Analyse les logs LOGGER pour classer les trains par inutilité de circulation."""
    import re
    from collections import defaultdict
    limit = min(int(request.args.get("limit", 1200)), 8000)
    entries = _log_ring[-limit:]

    trains = defaultdict(list)
    for e in entries:
        if e.get("tag") != "LOGGER":
            continue
        m = re.search(r"LOG: (.+?) (IN|OUT) (.+?)->(.+?) d=(\d+)s wagons=(\d+)(?:\s*\|\s*(.+?) x(\d+))?", e["msg"])
        if not m:
            continue
        name = m.group(1).strip()
        qty  = int(m.group(8)) if m.group(8) else 0
        trains[name].append({
            "dir": m.group(2), "from": m.group(3).strip(), "to": m.group(4).strip(),
            "dur": int(m.group(5)), "wagons": int(m.group(6)),
            "item": m.group(7), "qty": qty,
        })

    results = []
    for name, trips in trains.items():
        n = len(trips)
        if n < 2:
            continue
        avg_dur  = sum(t["dur"] for t in trips) / n
        with_qty = [t for t in trips if t["qty"] > 0]
        avg_qty  = sum(t["qty"] for t in with_qty) / len(with_qty) if with_qty else 0
        avg_wag  = sum(t["wagons"] for t in trips) / n
        lpw      = avg_qty / avg_wag if avg_wag > 0 else 0
        empty_r  = sum(1 for t in trips if t["qty"] == 0) / n
        stations = sorted(set(t["from"] for t in trips) | set(t["to"] for t in trips))
        last_item = with_qty[-1]["item"] if with_qty else None

        score  = empty_r * 50 + (n / 40) * 20
        if avg_qty > 0 and lpw < 2000:
            score += (1 - lpw / 2000) * 30

        # Verdict
        if empty_r == 1.0:
            verdict = "critical"
            label   = "100% vides"
        elif empty_r >= 0.4:
            verdict = "warning"
            label   = f"{empty_r*100:.0f}% vides"
        elif lpw < 300 and avg_qty > 0:
            verdict = "warning"
            label   = f"Très sous-chargé ({lpw:.0f} items/wagon)"
        elif lpw < 800 and avg_qty > 0:
            verdict = "info"
            label   = f"Sous-chargé ({lpw:.0f} items/wagon)"
        else:
            verdict = "ok"
            label   = f"{lpw:.0f} items/wagon"

        results.append({
            "name": name, "trips": n, "avg_dur": round(avg_dur),
            "avg_qty": round(avg_qty), "lpw": round(lpw),
            "empty_pct": round(empty_r * 100),
            "wagons": round(avg_wag), "stations": stations,
            "item": last_item, "score": round(score, 1),
            "verdict": verdict, "label": label,
        })

    results.sort(key=lambda x: -x["score"])
    period_from = entries[0]["ts"]  if entries else "—"
    period_to   = entries[-1]["ts"] if entries else "—"

    # Durée réelle couverte par les entrées
    duration_min = None
    try:
        from datetime import datetime
        fmt = "%d/%m %H:%M:%S"
        t0 = datetime.strptime(period_from, fmt)
        t1 = datetime.strptime(period_to,   fmt)
        duration_min = round((t1 - t0).total_seconds() / 60)
    except Exception:
        pass

    return jsonify({
        "period":       {"from": period_from, "to": period_to},
        "duration_min": duration_min,
        "total_trips":  sum(r["trips"] for r in results),
        "trains":       results[:10],
    })


@app.route("/api/logs")
def get_logs():
    """Endpoint dédié logs FIN / Dedicated FIN logs endpoint.
    ?after=N  → entrées depuis l'index N / entries from index N
    ?limit=M  → max M entrées (défaut 300, max 2000) / max M entries
    Sans after → retourne les M dernières / without after: returns last M entries
    """
    limit = min(int(request.args.get("limit", 300)), 2000)
    ring_size = len(_log_ring)
    # ring_start_abs = index absolu de _log_ring[0] / absolute index of _log_ring[0]
    ring_start_abs = _log_total_ever - ring_size
    after = request.args.get("after")
    if after is None:
        # Chargement initial : dernières `limit` entrées / initial load: last `limit` entries
        local_start = max(0, ring_size - limit)
    else:
        # Convertir index absolu JS → index local dans le ring / convert JS absolute index → local ring index
        local_start = max(0, int(after) - ring_start_abs)
    entries = _log_ring[local_start:local_start + limit]
    return jsonify({"logs": entries, "total": _log_total_ever, "start": ring_start_abs + local_start})


@app.route("/")
def index():
    """Sert index.html avec cache-buster sur les assets statiques."""
    web_dir = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(web_dir, "index.html"), "r", encoding="utf-8") as f:
        html = f.read()
    v = __version__
    html = html.replace('href="/static/style.css"',  f'href="/static/style.css?v={v}"')
    html = html.replace('src="/static/main.js"',      f'src="/static/main.js?v={v}"')
    from flask import Response
    return Response(html, mimetype="text/html")

@app.route("/<path:filename>")
def static_files(filename):
    return send_from_directory(os.path.dirname(os.path.abspath(__file__)), filename)


def run_flask():
    """Lance Flask dans un thread dédié (ne bloque pas le bot Discord)."""
    logging.getLogger("werkzeug").setLevel(logging.ERROR)
    print("Dashboard disponible sur http://0.0.0.0:8081")
    app.run(host="0.0.0.0", port=8081, debug=False, use_reloader=False, threaded=True)


# ════════════════════════════════════════════════════════════
# DISCORD — embed mis à jour périodiquement
# ════════════════════════════════════════════════════════════

intents = discord.Intents.default()
client  = discord.Client(intents=intents)

_monitor_msg = None  # message Discord à éditer


def _fmt_uptime(sec):
    sec = int(sec or 0)
    h, rem = divmod(sec, 3600)
    m, s   = divmod(rem, 60)
    return f"{h}h{m:02d}m{s:02d}s"


def _fmt_dur(sec):
    sec = int(sec or 0)
    return f"{sec // 60}:{sec % 60:02d}"


def _score_color(score):
    if score >= 80: return 0x33cc55
    if score >= 60: return 0xffcc00
    return 0xff4444


def build_embed():
    """Construit l'embed Discord — 3 champs inline (TRAINS / PERFORMANCE / SCORE)."""
    trains = _cache.get("trains", [])
    s      = _stats or {}

    moving_cnt  = s.get("movingCnt",  len([t for t in trains if t.get("status") == "moving"]))
    docked_cnt  = s.get("dockedCnt",  len([t for t in trains if t.get("status") == "docked"]))
    stopped_cnt = s.get("stoppedCnt", len([t for t in trains if t.get("status") == "stopped"]))
    total_cnt   = s.get("totalCnt",   len(trains))
    score       = s.get("score", 0)

    # Historique : dernier score connu
    hist = s.get("scoreHistory") or []
    if hist:
        score = hist[-1]

    embed = discord.Embed(
        title="🚂  TRAIN MONITOR — Satisfactory",
        color=_score_color(score)
    )

    # ── Champ 1 : TRAINS ─────────────────────────────────────
    trains_val = (
        f"🟢 En mouvement  **{moving_cnt}**\n"
        f"🔵 À quai        **{docked_cnt}**\n"
        f"🔴 À l'arrêt     **{stopped_cnt}**\n"
        f"─────────────────\n"
        f"⬜ Total          **{total_cnt}**"
    )
    embed.add_field(name="🚂  TRAINS", value=trains_val, inline=True)

    # ── Champ 2 : PERFORMANCE ────────────────────────────────
    dur_cnt  = s.get("durCnt", 0)
    avg_spd  = s.get("avgSpeed", 0)
    avg_dur  = s.get("avgDur", 0)
    avg_inv  = s.get("avgInv", 0)
    total_inv = s.get("totalInv", 0)

    perf_title = f"⚡  PERFORMANCE" + (f" ({dur_cnt} trajets)" if dur_cnt else "")
    spd_str  = f"**{avg_spd} km/h**" if avg_spd else "*N/A*"
    dur_str  = f"**{_fmt_dur(avg_dur)}**" if dur_cnt else "*N/A*"
    inv_str  = f"**{avg_inv}** · {total_inv}" if avg_inv else "*N/A*"
    perf_val = (
        f"Vitesse moy\n{spd_str}\n"
        f"Trajet moy\n{dur_str}\n"
        f"Moy · Circ.\n{inv_str} items"
    )
    embed.add_field(name=perf_title, value=perf_val, inline=True)

    # ── Champ 3 : SCORE ──────────────────────────────────────
    conf    = s.get("conf", "INCONNUE")
    uptime  = s.get("uptime", 0)

    score_emoji = "🟢" if score >= 80 else "🟡" if score >= 60 else "🔴"
    score_val = (
        f"{score_emoji} **{score} / 100**\n\n"
        f"Confiance\n**{conf}**\n\n"
        f"UP: {_fmt_uptime(uptime)}"
    )
    embed.add_field(name="📊  SCORE RÉSEAU", value=score_val, inline=True)

    embed.set_footer(text="Mis à jour")
    embed.timestamp = datetime.now(timezone.utc)
    return embed


@client.event
async def on_ready():
    global _monitor_msg
    print(f"Bot Discord connecté : {client.user}")

    # ── Purge des canaux configurés ──────────────────────────
    channels_to_clean = getattr(config, "CHANNELS_TO_CLEAN", [config.CHANNEL_ID])
    for ch_id in channels_to_clean:
        ch = client.get_channel(ch_id)
        if ch:
            deleted = await ch.purge(limit=None)
            print(f"Canal {ch_id} purgé ({len(deleted)} message(s))")
        else:
            print(f"Avertissement : canal {ch_id} introuvable (purge ignorée)")

    # ── Post initial de l'embed dans le canal principal ──────
    channel = client.get_channel(config.CHANNEL_ID)
    if not channel:
        print(f"ERREUR Discord : canal {config.CHANNEL_ID} introuvable — vérifie config.py")
        return

    _monitor_msg = await channel.send(embed=build_embed())
    print(f"Embed posté (id={_monitor_msg.id}), refresh toutes les {config.DISCORD_UPDATE_INTERVAL}s")
    asyncio.create_task(discord_update_loop())


async def discord_update_loop():
    global _monitor_msg
    while True:
        await asyncio.sleep(config.DISCORD_UPDATE_INTERVAL)
        if _monitor_msg:
            try:
                await _monitor_msg.edit(embed=build_embed())
            except discord.NotFound:
                channel = client.get_channel(config.CHANNEL_ID)
                if channel:
                    _monitor_msg = await channel.send(embed=build_embed())
            except Exception as e:
                print(f"Erreur Discord : {e}")


# ════════════════════════════════════════════════════════════
# POINT D'ENTRÉE
# ════════════════════════════════════════════════════════════

if __name__ == "__main__":
    print("Serveur démarré — en attente de données LOGGER via POST /api/push ...")
    print("Historique : session en cours uniquement (pas de persistence fichier)")

    # Flask dans un thread background
    flask_thread = threading.Thread(target=run_flask, daemon=True)
    flask_thread.start()

    # Bot Discord dans le thread principal (asyncio)
    client.run(config.BOT_TOKEN)
