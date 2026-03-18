"""
train_simple_server.py : serveur web pour Train Monitor — Satisfactory
- Base on train_server.py but without discord bot integration
- Flask : dashboard web sur le port 8081

Lancer : python train_server.py
Config  : renseigner config.py
"""

from flask import Flask, jsonify, send_from_directory, request
import json, os, time, logging

try:
    import config  # type: ignore
except ModuleNotFoundError:
    # Fallback minimal si config.py est absent
    class config:
        SITE_TITLE = "FN Monitor"



# ── Cache partagé pour le dashboard web ──────────────────────
# Alimenté par POST /api/push depuis LOGGER via InternetCard
_cache            = {"trains": [], "trips": {}}
_cache_updated_at = 0.0   # timestamp (epoch) du dernier push reçu de LOGGER
_trips            = {}    # historique de la session courante (en mémoire uniquement — pas de persistence)
_stats            = {}    # stats calculées par LOGGER (score, conf, avgSpeed, etc.)
_stockage         = {}    # données stockage par zone : {zone: {...}}

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


# ════════════════════════════════════════════════════════════
# FLASK — dashboard web
# ════════════════════════════════════════════════════════════

app = Flask(__name__)


@app.route("/api/push", methods=["POST"])
def receive_push():
    """Reçoit le snapshot trains + trips + stats + stockage de LOGGER (toutes les 2s)."""
    global _cache, _cache_updated_at, _trips, _stats, _stockage
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


@app.route("/api/data")
def get_data():
    # Auto-nettoyage TTL : zones sans update depuis > 10 min
    global _stockage
    now = time.time()
    _stockage = {k: v for k, v in _stockage.items() if (now - v.get("server_ts", 0)) <= _STOCKAGE_TTL}
    return jsonify({**_cache, "trips": _trips, "stats": _stats, "stockage": list(_stockage.values()), "logger_updated_at": _cache_updated_at, "site_title": getattr(config, "SITE_TITLE", "FN Monitor"), "stockage_order": _stockage_order})


@app.route("/")
def index():
    return send_from_directory(os.path.dirname(os.path.abspath(__file__)), "index.html")

@app.route("/<path:filename>")
def static_files(filename):
    return send_from_directory(os.path.dirname(os.path.abspath(__file__)), filename)


def run_flask():
    """Lance Flask."""
    logging.getLogger("werkzeug").setLevel(logging.ERROR)
    print("Dashboard disponible sur http://0.0.0.0:8081")
    app.run(host="0.0.0.0", port=8081, debug=False, use_reloader=False)


# ════════════════════════════════════════════════════════════
# POINT D'ENTRÉE
# ════════════════════════════════════════════════════════════

if __name__ == "__main__":
    print("Serveur démarré — en attente de données LOGGER via POST /api/push ...")
    print("Historique : session en cours uniquement (pas de persistence fichier)")
    run_flask()
