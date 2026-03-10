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
_stockage         = {}    # données stockage par zone : {zone: {...}}


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


@app.route("/api/data")
def get_data():
    return jsonify({**_cache, "trips": _trips, "stats": _stats, "stockage": list(_stockage.values()), "logger_updated_at": _cache_updated_at})


@app.route("/")
def index():
    return send_from_directory(os.path.dirname(os.path.abspath(__file__)), "index.html")

@app.route("/<path:filename>")
def static_files(filename):
    return send_from_directory(os.path.dirname(os.path.abspath(__file__)), filename)


def run_flask():
    """Lance Flask dans un thread dédié (ne bloque pas le bot Discord)."""
    logging.getLogger("werkzeug").setLevel(logging.ERROR)
    print("Dashboard disponible sur http://0.0.0.0:8081")
    app.run(host="0.0.0.0", port=8081, debug=False, use_reloader=False)


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
