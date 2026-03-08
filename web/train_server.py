"""
train_server.py : serveur web + bot Discord pour Train Monitor — Satisfactory
- Flask  : dashboard web sur le port 8081
- Discord: embed édité toutes les X secondes dans un canal (pas de notification)

Lancer : python train_server.py
Config  : renseigner config.py (token, channel_id)
"""

from flask import Flask, jsonify, send_from_directory, request
import json, os, threading, time
from datetime import datetime

import discord
import asyncio

import config

# ── Chemins ──────────────────────────────────────────────────
BASE_DIR   = os.path.dirname(os.path.abspath(__file__))
TRIPS_FILE = os.path.join(BASE_DIR, "trips.json")  # persistence locale (hors disque FIN)

# ── Cache partagé (Flask + Discord lisent le même) ───────────
# Alimenté par POST /api/push depuis LOGGER via InternetCard (plus de lecture fichier)
_cache            = {"trains": [], "trips": {}}
_cache_updated_at = 0.0   # timestamp (epoch) du dernier push reçu de LOGGER
_trips            = {}    # historique des trajets persisté dans trips.json


def _save_trips():
    """Persiste _trips dans trips.json (fichier Python, pas sur disque FIN)."""
    try:
        with open(TRIPS_FILE, "w", encoding="utf-8") as f:
            json.dump(_trips, f, ensure_ascii=False)
    except Exception:
        pass


def _load_trips():
    """Charge trips.json au démarrage de Python."""
    global _trips
    try:
        with open(TRIPS_FILE, "r", encoding="utf-8") as f:
            _trips = json.load(f)
        _cache["trips"] = _trips
    except Exception:
        _trips = {}


def _lua_serialize(v):
    """Convertit une valeur Python en Lua table (même format que ser() de LOGGER)."""
    if isinstance(v, str):
        return '"{}"'.format(v.replace("\\", "\\\\").replace('"', '\\"'))
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, list):
        return "{" + ",".join(_lua_serialize(x) for x in v) + "}"
    if isinstance(v, dict):
        pairs = []
        for k, val in v.items():
            ks = '["{}"]'.format(k) if isinstance(k, str) else "[{}]".format(k)
            pairs.append("{}={}".format(ks, _lua_serialize(val)))
        return "{" + ",".join(pairs) + "}"
    return "nil"


# ════════════════════════════════════════════════════════════
# FLASK — dashboard web
# ════════════════════════════════════════════════════════════

app = Flask(__name__)


@app.route("/api/push", methods=["POST"])
def receive_push():
    """Reçoit le snapshot trains + trips de LOGGER (toutes les 30s)."""
    global _cache, _cache_updated_at, _trips
    body = request.get_json(silent=True)
    if not body:
        return jsonify({"error": "Body JSON manquant"}), 400
    _cache = body
    _cache_updated_at = time.time()
    if isinstance(body.get("trips"), dict) and body["trips"]:
        _trips = body["trips"]
        _save_trips()
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
    _save_trips()
    return jsonify({"status": "ok"})


@app.route("/api/trips-lua", methods=["GET"])
def get_trips_lua():
    """Retourne l'historique en format Lua table — utilisé par LOGGER au démarrage."""
    return _lua_serialize(_trips), 200, {"Content-Type": "text/plain; charset=utf-8"}


@app.route("/api/data")
def get_data():
    return jsonify({**_cache, "logger_updated_at": _cache_updated_at})


@app.route("/")
def index():
    return send_from_directory(BASE_DIR, "index.html")


def run_flask():
    """Lance Flask dans un thread dédié (ne bloque pas le bot Discord)."""
    print("Dashboard disponible sur http://0.0.0.0:8081")
    app.run(host="0.0.0.0", port=8081, debug=False, use_reloader=False)


# ════════════════════════════════════════════════════════════
# DISCORD — embed mis à jour périodiquement
# ════════════════════════════════════════════════════════════

intents = discord.Intents.default()
client  = discord.Client(intents=intents)

_monitor_msg = None  # message Discord à éditer


def _field_value(trains_list, status):
    """Formate la liste de trains pour un champ embed (max 1024 chars)."""
    if not trains_list:
        return "*(aucun)*"
    lines = []
    for t in trains_list:
        name    = t.get("name", "?")
        station = t.get("station", "?")
        if status == "moving":
            lines.append(f"`{t.get('speed', 0)} km/h`  **{name}**  →  {station}")
        elif status == "docked":
            lines.append(f"**{name}**  @  {station}")
        else:
            lines.append(f"**{name}**  —  {station}")
    value = "\n".join(lines)
    if len(value) > 1020:
        value = value[:1017] + "…"
    return value


def build_embed():
    """Construit l'embed Discord depuis le cache actuel."""
    trains = _cache.get("trains", [])
    groups = {"moving": [], "docked": [], "stopped": []}
    for t in trains:
        groups.get(t.get("status", "stopped"), groups["stopped"]).append(t)
    groups["moving"].sort(key=lambda t: -t.get("speed", 0))

    total = len(trains)
    embed = discord.Embed(
        title="🚂  TRAIN MONITOR — Satisfactory",
        description=(
            f"**{total}** train{'s' if total != 1 else ''} sur le réseau\n\u200b"
        ),
        color=(
            0x33cc55 if len(groups["moving"]) > len(groups["stopped"])
            else 0xff4444 if len(groups["stopped"]) > len(groups["moving"])
            else 0xff8800
        )
    )
    embed.add_field(
        name=f"🔴 À L'ARRÊT ({len(groups['stopped'])})",
        value=_field_value(groups["stopped"], "stopped"),
        inline=False
    )
    moving_display = groups["moving"][:10]
    moving_extra   = len(groups["moving"]) - len(moving_display)
    moving_value   = _field_value(moving_display, "moving")
    if moving_extra:
        moving_value += f"\n*… et {moving_extra} autre{'s' if moving_extra > 1 else ''}*"
    embed.add_field(
        name=f"🟢 EN MOUVEMENT ({len(groups['moving'])})",
        value=moving_value,
        inline=False
    )
    embed.add_field(
        name=f"🔵 À QUAI ({len(groups['docked'])})",
        value=_field_value(groups["docked"], "docked"),
        inline=False
    )
    embed.set_footer(text="Mis à jour")
    embed.timestamp = datetime.utcnow()
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
        # _cache est mis à jour par POST /api/push — pas besoin de lire un fichier
        if _monitor_msg:
            try:
                await _monitor_msg.edit(embed=build_embed())
            except discord.NotFound:
                # Message supprimé manuellement → on en reposte un
                channel = client.get_channel(config.CHANNEL_ID)
                if channel:
                    _monitor_msg = await channel.send(embed=build_embed())
            except Exception as e:
                print(f"Erreur Discord : {e}")


# ════════════════════════════════════════════════════════════
# POINT D'ENTRÉE
# ════════════════════════════════════════════════════════════

if __name__ == "__main__":
    _load_trips()
    print(f"Historique chargé : {len(_trips)} train(s) dans trips.json")
    print("En attente de données LOGGER via POST /api/push ...")

    # Flask dans un thread background
    flask_thread = threading.Thread(target=run_flask, daemon=True)
    flask_thread.start()

    # Bot Discord dans le thread principal (asyncio)
    client.run(config.BOT_TOKEN)
