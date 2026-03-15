# Tableau de bord FN (web)

Instructions rapides pour faire tourner le dashboard Flask (avec ou sans bot Discord).

## Preparation
- Python 3.9+ recommande.
- Si tu veux le bot Discord, copie `config.example.py` en `config.py`, puis remplis `BOT_TOKEN`, `CHANNEL_ID` et eventuellement `CHANNELS_TO_CLEAN`. Ne commite pas `config.py`.

## Installation
```bash
cd Ficsit-Networks-CMK/web
python -m venv .venv
source .venv/bin/activate  # sous Windows : .venv\Scripts\activate
pip install -r requirements.txt
```

## Lancement
- Dashboard + bot Discord : `python train_server.py`
- Dashboard seul (sans Discord) : `python train_simple_server.py`

Le dashboard est accessible sur http://0.0.0.0:8081. Le logger du jeu doit envoyer ses snapshots JSON sur `POST /api/push` (et `/api/trips` pour l'historique complet).
