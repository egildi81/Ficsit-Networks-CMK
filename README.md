# Monitor Ficsit Network by CMK — Satisfactory Train & Storage Network

Système de supervision en temps réel d'un réseau ferroviaire Satisfactory, conçu avec **Ficsit-Networks (FIN)**.
Architecture distribuée : plusieurs ordinateurs FIN communiquent par réseau local, publient leurs données vers un serveur Python, et exposent un dashboard web + overlay OBS.

> Ce projet est développé avec l'assistance de **Claude (Anthropic)** — IA qui réalise la quasi-totalité du code Lua, Python et HTML/CSS/JS sur la base des besoins fonctionnels définis par le guide du projet.

---

## Aperçu

```
Satisfactory (FIN Lua)                    Serveur local (Python)         Navigateur / OBS
──────────────────────────────────────    ──────────────────────────     ───────────────────
LOGGER  ─── réseau FIN ──▶ TRAIN_TAB      Flask :8081
        ─── réseau FIN ──▶ TRAIN_STATS    POST /api/push  ◀── LOGGER     index.html (dashboard)
        ─── réseau FIN ──▶ DETAIL         GET  /api/data  ──▶ browser    overlay.html (OBS)
        ─── HTTP POST ───▶ train_server   POST /api/trips ◀── LOGGER
STOCKAGE ── réseau FIN ──▶ LOGGER
TOUS ────── réseau FIN ──▶ GET_LOG
```

---

## Composants du projet

### Scripts FIN (Lua) — `fin/`

| Script | Ordinateur FIN | Rôle |
|--------|---------------|------|
| `LOGGER.lua` | LOGGER | Hub central : surveille les trains, calcule toutes les stats, pousse les données vers le serveur web |
| `TRAIN_TAB.lua` | TRAIN_TAB | Dashboard 3 écrans : trains à l'arrêt / en mouvement / à quai |
| `TRAIN_STATS.lua` | TRAIN_STATS | Écran métriques réseau (score, vitesse, confiance, historique) |
| `DETAIL.lua` | DETAIL | Détail d'un train + liste de navigation (2 écrans, panel boutons) |
| `GET_LOG.lua` | GET_LOG | Agrège et affiche tous les logs réseau de la session |
| `STOCKAGE.lua` | STOCKAGE (x N) | Monitore des conteneurs MK2, calcule taux de remplissage et vitesse, envoie vers LOGGER |

### Serveur web (Python) — `web/`

| Fichier | Rôle |
|---------|------|
| `train_server.py` | Serveur Flask (port 8081) + bot Discord ; reçoit les données de LOGGER, les expose via API REST |
| `index.html` | Dashboard web complet : trains, trajets, stats, stockage (cards déplaçables) |
| `overlay.html` | Overlay OBS/navigateur : 3 skins (ticker bas, ticker haut, terminal) avec carrousel trains/stockage |
| `config.py` | Configuration locale (token Discord, channel ID, titre — **non commité**) |
| `config.example.py` | Template de configuration |

---

## Architecture réseau FIN

Toute communication entre ordinateurs FIN passe par **NetworkCard** via `net:broadcast()` (diffusion) ou `net:send()` (point-à-point ciblé).
La règle universelle : **chaque `print()` de chaque script est redirigé sur le port 43** vers GET_LOG, jamais affiché localement.

```
Port 42  broadcast   Trajet complet (train, départ, arrivée, durée, inventaire)    LOGGER → DETAIL
Port 43  broadcast   Logs texte (script, message)                                   TOUS   → GET_LOG
Port 44  broadcast   Snapshot état trains (table Lua sérialisée)                    LOGGER → TRAIN_TAB, TRAIN_STATS
Port 45  broadcast   Stats ETA par segment (train, segment, avg, count)             LOGGER → DETAIL
Port 46  broadcast   Beacon LOGGER_ADDR + handshake WHO_IS_LOGGER                   LOGGER ↔ STOCKAGE
Port 47  broadcast   Stats calculées (score, vitesse, confiance, historique…)       LOGGER → TRAIN_STATS
Port 48  net:send    Données stockage (zone, fill%, items, vitesse)                 STOCKAGE → LOGGER
Port 49  net:send    Requêtes/réponses point-à-point (stats + stockage à la demande) ANY → LOGGER
```

---

## Flux de données détaillé

### 1. Surveillance des trains (LOGGER)

LOGGER est l'**unique source de vérité**. Il interroge le graphe de voies via la station `GARE_TEST` toutes les 2 secondes :

- Filtre les trains valides (master locomotive + timetable avec stops > 0)
- Détecte les changements d'état (moving / docked / stopped)
- Enregistre chaque trajet complet (départ, arrivée, durée, inventaire)
- Calcule **toutes les stats** : vitesse moyenne, durée moyenne, score réseau, confiance, historique des scores

**Broadcast port 44** → TRAIN_TAB (snapshot état) et TRAIN_STATS (reçoit aussi les stats port 47)
**Broadcast port 42** → DETAIL (trajet complet à chaque fin de trajet)
**HTTP POST /api/push** → serveur Python (snapshot + trips + stats + stockage toutes les 2s)

### 2. Score réseau

Le score (0–100) est calculé par LOGGER seul, sur deux axes :

- **Mobilité (60%)** : proportion de trains en mouvement
- **Consistance (40%)** : régularité des durées de trajet (coefficient de variation)

La **confiance** reflète la fiabilité du score selon trois critères pondérés : mobilité des trains (50%), nombre de trajets enregistrés (30%), uptime LOGGER (20%). Résultat : HAUTE / BONNE / FAIBLE / INEXISTANTE.

### 3. Stockage (STOCKAGE → LOGGER)

Chaque instance de `STOCKAGE.lua` gère une zone nommée (ex : `ELECT`, `CIRCUIT`…) :

1. Au démarrage, broadcast `WHO_IS_LOGGER` sur port 46 → LOGGER répond avec son adresse réseau
2. Toutes les **60 secondes** (SCAN_INTERVAL), STOCKAGE scanne ses conteneurs MK2, calcule fill%, items, vitesse items/min
3. Envoie les données à LOGGER via `net:send(loggerAddr, 48, …)` (ciblé) ou broadcast fallback
4. LOGGER agrège toutes les zones dans `stockageData{}`, déduplique par nom de zone, et inclut les données dans le prochain push HTTP

> La boucle d'attente utilise `event.pull` en boucle avec deadline pour éviter que les beacons LOGGER_ADDR (port 46, toutes les 2s) ne relancent le scan prématurément.

**Déduplication** : si deux instances STOCKAGE déclarent la même zone (reboot réseau), LOGGER garde la plus récente et log un avertissement une seule fois via `_knownDups`.

### 4. Serveur Python (Flask)

- `POST /api/push` : reçoit le snapshot complet de LOGGER toutes les 2s
- `POST /api/trips` : reçoit l'historique des trajets (appelé après chaque trajet)
- `GET /api/data` : exposé au navigateur — trains, trips, stats, stockage, site_title, stockage_order
- `POST /api/stockage-order` : sauvegarde l'ordre des cards stockage dans `stockage_order.json` (persisté)
- `POST /api/stockage-purge` : supprime manuellement les zones inactives (server_ts > 120s)

**TTL automatique** : les zones sans update depuis plus de **10 minutes** sont supprimées silencieusement lors du prochain `/api/data`.

Le bot Discord (dans le même process) édite un embed périodiquement dans un canal configuré, sans créer de nouvelle notification.

---

## Dashboard Web (`index.html`)

Section **TRAINS** :
- Onglets : Liste des trains, Stats réseau, Détail trajet, Historique
- Tableau d'état temps réel (status, vitesse, position)
- Métriques : score coloré, confiance, vitesse/durée moyennes, histogramme des scores

Section **STOCKAGE** :
- Cards déplaçables (drag & drop HTML5 natif) par zone
- Ordre persisté côté serveur (cohérence mobile/PC)
- Indicateur de remplissage coloré (vert → jaune → rouge)
- Badge ⚠️ si doublon de zone détecté par LOGGER
- Opacité réduite si zone inactive (server_ts > 120s)
- Bouton **"Purger les inactives"** avec feedback visuel
- Modal détail au clic : tous les items, slots, vitesse

---

## Overlay OBS (`overlay.html`)

3 skins sélectionnables (via boutons ou paramètre URL `?skin=`) :

| Skin | Description |
|------|-------------|
| `ticker` | Bande fine en bas d'écran |
| `ticker-top` | Bande fine en haut d'écran |
| `terminal` | Panel compact style monitoring industriel (coin haut-droit) |

**Carrousel automatique (ticker bas/haut)** : rotation toutes les 7s avec fondu (0.7s) entre :
- Page TRAINS : compteurs, score, confiance, vitesse moy., uptime
- Page STOCKAGE : chaque zone active avec fill% coloré et slots (si données disponibles)

**Terminal** : affiche trains + bloc STOCKAGE en bas (zones actives avec barre de remplissage).

**Paramètres URL** :
```
overlay.html?skin=ticker-top   → ticker en haut
overlay.html?obs=1             → masque le sélecteur de skin (mode OBS)
overlay.html?alpha=0.8         → opacité des bordures orange (défaut: 0.45)
```

---

## Installation

### Prérequis
- Satisfactory + mod **Ficsit-Networks (FIN)**
- Python 3.10+ avec `flask` et `discord.py`

### Mise en place

```bash
# Cloner le repo
git clone https://github.com/CaMaK/Ficsit-Networks-CMK.git

# Configurer le serveur
cd web
cp config.example.py config.py
# Éditer config.py : BOT_TOKEN, CHANNEL_ID, SITE_TITLE

# Installer les dépendances Python
pip install flask discord.py

# Lancer le serveur
python train_server.py
```

### En jeu (FIN)

1. Placer un ordinateur FIN pour chaque script, câbler NetworkCard + composants requis
2. Nommer les composants selon les constantes des scripts (ex : `GARE_TEST`, `TAB_SCREEN_L`, `TRAFFIC_POLE`…)
3. Copier chaque script `.lua` dans le computer correspondant via l'interface FIN
4. Lancer les scripts — LOGGER en dernier pour éviter les timeouts de découverte

### Composants en jeu requis

| Nom en jeu | Utilisé par | Type |
|------------|-------------|------|
| `GARE_TEST` | LOGGER, DETAIL | Station (pour `getTrackGraph()`) |
| `TAB_SCREEN_L/C/R` | TRAIN_TAB | 3x GPU T2 + écrans |
| `STATS_SCREEN` | TRAIN_STATS | GPU T2 + écran |
| `DETAIL_SCREEN_R/L` | DETAIL | 2x GPU T2 + écrans |
| `DETAIL_PANEL2` | DETAIL | Panel modulaire avec boutons `(4,8)` gauche, `(6,8)` droit, LED `(5,8)` |
| `MAP_SCREEN` | GET_LOG | GPU T2 + écran |
| `TRAFFIC_POLE` | TRAIN_TAB | Pole modulaire avec LEDs (vert x=0, jaune x=1, rouge x=2) |
| `TRAFFIC_SPEAKER` | TRAIN_TAB | Speaker Pole pour sons custom |
| `STOCKAGE_1`, `STOCKAGE_2`… | STOCKAGE | Conteneurs MK2 (noms configurables dans `STOCKAGE.lua`) |

---

## Configuration multi-zones stockage

Chaque zone de stockage est une **instance séparée** de `STOCKAGE.lua` sur son propre ordinateur FIN.
Éditer en tête de script :

```lua
local CONTAINER_NAMES = { "STOCKAGE_1", "STOCKAGE_2" }  -- nicknames des conteneurs MK2
local ZONE_NAME       = "ELECT"   -- nom unique affiché dans le dashboard
local SCAN_INTERVAL   = 60        -- secondes entre chaque scan
```

---

## Structure du repo

```
Ficsit-Networks-CMK/
├── fin/
│   ├── LOGGER.lua        Hub central trains + stockage
│   ├── TRAIN_TAB.lua     Dashboard 3 écrans
│   ├── TRAIN_STATS.lua   Métriques réseau
│   ├── DETAIL.lua        Détail train + navigation
│   ├── GET_LOG.lua       Console logs réseau
│   └── STOCKAGE.lua      Moniteur conteneurs
├── web/
│   ├── train_server.py   Flask + Discord bot
│   ├── index.html        Dashboard web
│   ├── overlay.html      Overlay OBS
│   ├── config.example.py Template config
│   └── config.py         Config locale (ignoré git)
└── docs/
    ├── score-reseau.md   Détail du calcul de score
    └── inventaire-api.md Référence API FIN utilisée
```

---

## Crédits

Projet Satisfactory personnel.
Code réalisé en collaboration avec **Claude (Anthropic)** — assistant IA ayant conçu et implémenté l'architecture réseau FIN, les algorithmes de calcul de stats, le serveur Python, le dashboard web et l'overlay OBS.
Direction fonctionnelle, tests en jeu et validation : le Guide du projet.
