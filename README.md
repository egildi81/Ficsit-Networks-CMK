# Monitor Ficsit Network by CMK — Satisfactory Train & Storage Network

> **Documentation en français** — English version below / [Jump to English](#english-version)

Système de supervision en temps réel d'un réseau ferroviaire Satisfactory, conçu avec **Ficsit-Networks (FIN)**.
Architecture distribuée : plusieurs ordinateurs FIN communiquent par réseau local, publient leurs données vers un serveur Python, et exposent un dashboard web + overlay OBS.

> Ce projet est développé avec l'assistance de **Claude (Anthropic)** — IA qui réalise la quasi-totalité du code Lua, Python et HTML/CSS/JS sur la base des besoins fonctionnels définis par le guide du projet.

---

## Aperçu

```
Satisfactory (FIN Lua)                         Serveur local (Python)           Navigateur / OBS
───────────────────────────────────────────    ─────────────────────────────    ──────────────────────
LOGGER  ─── réseau FIN ──▶ TRAIN_TAB           Flask :8081
        ─── réseau FIN ──▶ TRAIN_STATS         POST /api/push            ◀── LOGGER       index.html (dashboard)
        ─── réseau FIN ──▶ DETAIL              GET  /api/data            ──▶ browser      overlay.html (OBS)
        ─── HTTP POST ───▶ train_server        POST /api/trips           ◀── LOGGER
DISPATCH ── HTTP GET ────▶ train_server        POST /api/stockage/central/push ◀── STOCKAGE_CENTRAL
POWER_MON ─ réseau FIN ──▶ LOGGER
STOCKAGE_SATELLITE (x N) ── réseau FIN (port 56/57) ──▶ STOCKAGE_CENTRAL ── HTTP POST ──▶ train_server
TOUS ────── réseau FIN ──▶ GET_LOG
```

---

## Composants du projet

### Scripts FIN (Lua) — `fin/`

| Script | Ordinateur FIN | Rôle |
|--------|----------------|------|
| `LOGGER.lua` | LOGGER | Hub central : surveille les trains, calcule toutes les stats, pousse les données vers le serveur web |
| `DISPATCH.lua` | DISPATCH | Dispatch intelligent multi-routes : décide GO/HOLD selon le niveau des buffers, réécrit les timetables |
| `STARTER.lua` | STARTER | Séquence de démarrage/arrêt du réseau, feu tricolore animé, contrôle des autres ordinateurs |
| `TRAIN_TAB.lua` | TRAIN_TAB | Dashboard 3 écrans : trains à l'arrêt / en mouvement / à quai |
| `TRAIN_STATS.lua` | TRAIN_STATS | Écran métriques réseau (score, vitesse, confiance, historique) |
| `TRAIN_MAP.lua` | TRAIN_MAP | Carte temps réel des trains, positions et stations |
| `DETAIL.lua` | DETAIL | Détail d'un train + liste de navigation (2 écrans, panel boutons) |
| `GET_LOG.lua` | GET_LOG | Agrège et affiche tous les logs réseau de la session (console réseau) |
| `STOCKAGE_CENTRAL.lua` | STOCKAGE_CENTRAL | Hub de stockage : reçoit les données de tous les satellites, agrège, push HTTP vers le serveur. Poll les commandes web (reboot, mode rapide) |
| `STOCKAGE_SATELLITE.lua` | SAT (× N) | Satellite de stockage : découvre les conteneurs FIN locaux, scanne les inventaires, envoie les données à CENTRAL |
| `POWER_MON.lua` | POWER_MON | Monitore le réseau électrique (production, consommation, capacité, batteries), envoie vers LOGGER |

**Scripts EEPROM** (bootloaders) : `LOGGER_EEPROM.lua`, `DISPATCH_EEPROM.lua`, `GETLOG_EEPROM.lua` — chargés en premier, ils initialisent le réseau avant de lancer le script principal.

**Scripts de debug** (non déployés en production) : `COMPSCAN.lua`, `LOCO_SCAN.lua`, `PANELSCAN.lua`, `SCREEN_PROBE.lua`

### Serveur web (Python) — `web/`

| Fichier | Rôle |
|---------|------|
| `train_server.py` | Serveur Flask (port 8081) + bot Discord ; reçoit les données de LOGGER et DISPATCH, expose une API REST complète |
| `index.html` | Dashboard web complet : trains, trajets, stats, stockage, dispatch, performances (cards déplaçables) |
| `overlay.html` | Overlay OBS/navigateur : 3 skins (ticker bas, ticker haut, terminal) avec carrousel trains/stockage |
| `config.py` | Configuration locale (token Discord, channel ID, titre — **non commité**) |
| `config.example.py` | Template de configuration |

---

## Architecture réseau FIN

Toute communication entre ordinateurs FIN passe par **NetworkCard** via `net:broadcast()` (diffusion) ou `net:send()` (point-à-point ciblé).
Règle universelle : **chaque `print()` de chaque script est redirigé sur le port 43** vers GET_LOG via broadcast.

```
Port 42  broadcast        Trajet complet (train, départ, arrivée, durée, inventaire)   LOGGER → DETAIL
Port 43  broadcast        Logs texte (script, message)                                  TOUS   → GET_LOG
Port 44  broadcast        Snapshot état trains (table Lua sérialisée)                   LOGGER → TRAIN_TAB, TRAIN_STATS, DISPATCH
Port 45  broadcast        Stats ETA par segment (train, segment, avg, count)            LOGGER → DETAIL
Port 46  broadcast+send   Beacon LOGGER_ADDR + handshake WHO_IS_LOGGER                  LOGGER ↔ STOCKAGE
Port 47  broadcast        Stats calculées (score, vitesse, confiance, historique…)      LOGGER → TRAIN_STATS
Port 48  net:send         Données stockage (zone, fill%, items, vitesse)                STOCKAGE → LOGGER
Port 49  net:send         Requêtes/réponses point-à-point (stats + stockage à la demande) ANY → LOGGER
Port 50  broadcast        SHUTDOWN — signal d'extinction de tous les ordinateurs        STARTER → TOUS
Port 51  broadcast        Stats réseau électrique (prod, conso, capacité, batteries)    POWER_MON → LOGGER
Port 55  broadcast+send   Priorité buffers DISPATCH (mode rapide 2s) + PRIORITY_REQUEST DISPATCH ↔ STOCKAGE
Port 56  net:send         Données scan inventaire (table Lua sérialisée)             SATELLITE → CENTRAL
Port 57  broadcast+send   Découverte + commandes (SATELLITE_HERE, CENTRAL_ADDR, CONTAINERS_REPORT, REBOOT, FAST_MODE) SATELLITE ↔ CENTRAL
```

> **Note :** DISPATCH et STOCKAGE_CENTRAL utilisent une **InternetCard** pour communiquer avec le serveur Flask (config routes, push données, poll commandes).

---

## Flux de données détaillé

### 1. Surveillance des trains (LOGGER)

LOGGER est l'**unique source de vérité trains**. Il interroge le graphe de voies via la station `GARE_TEST` toutes les 2 secondes :

- Filtre les trains valides (master locomotive + timetable avec stops > 0)
- Détecte les changements d'état (moving / docked / stopped)
- Enregistre chaque trajet complet (départ, arrivée, durée, inventaire)
- Calcule **toutes les stats** : vitesse moyenne, durée moyenne, score réseau, confiance, historique

**Broadcast port 44** → TRAIN_TAB, TRAIN_STATS, DISPATCH (snapshot état)
**Broadcast port 42** → DETAIL (trajet complet à chaque fin de trajet)
**Broadcast port 47** → TRAIN_STATS (stats calculées)
**HTTP POST /api/push** → serveur Python (snapshot complet toutes les 2 s)

### 2. Dispatch intelligent (DISPATCH)

DISPATCH gère l'envoi des trains de livraison selon le niveau réel des buffers.

**Démarrage :** l'EEPROM récupère la config des routes depuis Flask (`GET /api/dispatch/routes.lua`) avant de démarrer le script principal.

**Cycle de décision (toutes les 2 s) :**
1. Reçoit le snapshot trains via port 44 (LOGGER)
2. Reçoit les données stockage de STOCKAGE via port 55 (mode rapide)
3. Pour chaque route configurée :
   - **HOLD** si le buffer n'est pas assez approvisionné : timetable vidée + `setSelfDriving(false)` → train retenu à la gare PARK
   - **GO** si le buffer est suffisant : timetable réécrite `[PARK → LIVRAISON]` + `setSelfDriving(true)` → train parti
   - **URGENCE** si slots ≤ MIN_BUF_SLOTS : GO forcé prioritaire
4. Limite `MAX_EN_ROUTE` trains simultanément en livraison par route
5. Heartbeat port 55 vers STOCKAGE → active le scan rapide (2 s) sur les buffers concernés

**Commandes à distance :** Flask expose `GET/POST /api/dispatch/command` — permet de forcer GO/HOLD/AUTO depuis le dashboard web.

**Rapport DISPATCH :** modal web avec historique complet des décisions (GO/HOLD, raison, horodatage) via `GET /api/dispatch/report`.

### 3. Score réseau

Le score (0–100) est calculé par LOGGER seul, sur deux axes :

- **Mobilité (60%)** : proportion de trains en mouvement
- **Consistance (40%)** : régularité des durées de trajet (coefficient de variation)

La **confiance** reflète la fiabilité du score : mobilité (50%), nombre de trajets (30%), uptime LOGGER (20%). Résultat : HAUTE / BONNE / FAIBLE / INEXISTANTE.

### 4. Stockage (SATELLITE → CENTRAL → Flask)

Architecture distribuée en deux niveaux :

**STOCKAGE_SATELLITE** (une instance par zone physique) :
1. Au boot, broadcast port 57 `SATELLITE_HERE` + NICK → CENTRAL répond avec son adresse
2. Scanne les conteneurs FIN locaux selon le mode : **60 s** (normal) ou **2 s** (rapide si DISPATCH surveille ces buffers)
3. Envoie les données via `net:send(centralAddr, 56, …)` : fill%, items, slots, détail par conteneur, `version` du script
4. Si pas de heartbeat CENTRAL depuis `FAST_EXPIRY` secondes → retour mode normal automatique

**STOCKAGE_CENTRAL** (une instance unique) :
1. Reçoit les données de tous les satellites sur le port 56, les agrège
2. Push HTTP vers Flask (`POST /api/stockage/central/push`) à chaque scan reçu
3. Poll Flask toutes les 5 s (`POST /api/stockage/central/command.lua`) pour les commandes web
4. Relaye les commandes REBOOT / FAST_MODE aux satellites via `net:send` port 57

### 5. Électricité (POWER_MON → LOGGER)

`POWER_MON.lua` surveille le circuit électrique principal et broadcast sur port 51 : production, consommation, capacité totale, état des batteries. LOGGER intègre ces données dans le push HTTP.

### 6. Serveur Python (Flask)

```
POST /api/push                          → snapshot complet de LOGGER (trains, stats, stockage, power)
POST /api/trips                         → historique des trajets
GET  /api/data                          → données complètes pour le navigateur (inclut satellite_versions, sat_update_results, sat_latest_version)
POST /api/stockage-order                → ordre des cards stockage (persisté)
POST /api/stockage-purge                → suppression manuelle des zones inactives
GET  /api/dispatch/routes               → config des routes DISPATCH (JSON)
GET  /api/dispatch/routes.lua           → config routes au format Lua (pour EEPROM)
PUT  /api/dispatch/routes               → mise à jour de la config routes
GET  /api/dispatch/command              → commande en attente pour DISPATCH
POST /api/dispatch/command              → émet une commande (GO/HOLD/AUTO)
GET  /api/dispatch/report               → historique des décisions DISPATCH
GET  /api/perf/trains                   → analyse "Check Perf" : top 10 trains inutiles (scores par fenêtre)
GET  /api/logs                          → logs réseau bruts (ring buffer 15 000 entrées)
POST /api/stockage/central/push         → CENTRAL → Flask : données agrégées + liste satellites (versions)
POST /api/stockage/central/command.lua  → CENTRAL poll commande en attente (format Lua, timeout 60 s)
POST /api/stockage/satellite/reboot     → Dashboard → Flask : déclenche reboot séquentiel satellite(s)
```

**Rétention des logs :** ring buffer 15 000 entrées en mémoire (~1 h de logs à pleine cadence), persisté sur disque au redémarrage.

**TTL stockage :** zones sans update depuis plus de 10 minutes supprimées automatiquement lors du prochain `/api/data`.

Le bot Discord (même process) édite un embed périodiquement dans un canal configuré, sans notification.

---

## Dashboard Web (`index.html`)

### Section TRAINS

Onglets :
- **Liste** : état temps réel de chaque train (status, vitesse, position)
- **Statistiques** : score coloré, confiance, vitesse/durée moyennes, histogramme des scores
- **Check Perf** : analyse des trains les moins utiles sur une fenêtre (15 min / 30 min / 1 h) — score basé sur les trajets à vide, la fréquence et la charge par wagon

### Section DISPATCH

- Tableau des routes actives avec état GO/HOLD, niveau du buffer, nombre de trains en route
- Bouton **Rapport** : modal historique des décisions avec horodatage et raison
- Commandes manuelles depuis l'interface (forcer GO/HOLD/AUTO)

### Section STOCKAGE

3 onglets :

**INFO :**
- Cards par zone avec indicateur de remplissage coloré (vert → jaune → rouge)
- Drag & drop HTML5 natif, ordre persisté côté serveur (cohérence mobile/PC)
- Opacité réduite si zone inactive (server_ts > 120 s)
- Modal détail : tous les items, slots, détail par conteneur
- Basculer entre vue synthèse et vue détaillée

**CONFIGURATION :**
- Réglages par satellite : filtres d'items, sticky pool, collapse zones, recherche

**MISE À JOUR :**
- Suivi de version par satellite (version courante vs version de référence dans le dépôt)
- Badge « Obsolète » (rouge) si le satellite tourne une version antérieure
- Bouton « Mettre à jour » par satellite ou « Tout mettre à jour » (reboot séquentiel)
- Bouton filtre « Obsolètes » : affiche uniquement les satellites non à jour (sans déclencher de reboot)

---

## Overlay OBS (`overlay.html`)

3 skins sélectionnables (via boutons ou paramètre URL `?skin=`) :

| Skin | Description |
|------|-------------|
| `ticker` | Bande fine en bas d'écran |
| `ticker-top` | Bande fine en haut d'écran |
| `terminal` | Panel compact style monitoring industriel (coin haut-droit) |

**Carrousel automatique (ticker bas/haut)** : rotation toutes les 7 s entre trains, score/stats et zones stockage.

**Paramètres URL :**
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
git clone https://github.com/CaMaK/Ficsit-Networks-CMK.git
cd web
cp config.example.py config.py
# Éditer config.py : BOT_TOKEN, CHANNEL_ID, SITE_TITLE
pip install flask discord.py
python train_server.py
```

### En jeu (FIN)

1. Placer un ordinateur FIN pour chaque script, câbler NetworkCard + composants requis
2. Nommer les composants selon les constantes des scripts (ex : `GARE_TEST`, `TAB_SCREEN_L`, `TRAFFIC_POLE`…)
3. Charger d'abord le script **EEPROM** correspondant dans chaque computer (s'il existe), puis le script principal
4. Lancer les scripts — LOGGER en dernier pour éviter les timeouts de découverte

### Composants en jeu requis

| Nom en jeu | Utilisé par | Type |
|------------|-------------|------|
| `GARE_TEST` | LOGGER, DETAIL | Station (pour `getTrackGraph()`) |
| `TAB_SCREEN_L/C/R` | TRAIN_TAB | 3× GPU T2 + écrans |
| `STATS_SCREEN` | TRAIN_STATS | GPU T2 + écran |
| `DETAIL_SCREEN_R/L` | DETAIL | 2× GPU T2 + écrans |
| `DETAIL_PANEL2` | DETAIL | Panel modulaire avec boutons `(4,8)` gauche, `(6,8)` droit, LED `(5,8)` |
| `MAP_SCREEN` | GET_LOG | GPU T2 + écran |
| `TRAINMAP_SCREEN` | TRAIN_MAP | GPU T2 + écran |
| `POWER_SCREEN` | POWER_MON | GPU T2 + écran |
| `TRAFFIC_POLE` | TRAIN_TAB | Pole modulaire avec LEDs (vert x=0, jaune x=1, rouge x=2) |
| `TRAFFIC_SPEAKER` | TRAIN_TAB | Speaker Pole pour sons custom |
| `PANEL_L` | STARTER | Panel principal avec switches `(2,6)` et `(8,6)` |
| `POWER_POLE` | POWER_MON | Composant power (nick configurable dans POWER_MON) |
| `STOCKAGE_1`, `STOCKAGE_2`… | STOCKAGE | Conteneurs MK2 (noms configurables dans `STOCKAGE.lua`) |

---

## Configuration STOCKAGE — architecture SATELLITE/CENTRAL

Le système de stockage est distribué en deux niveaux :

- **STOCKAGE_SATELLITE** : une instance par zone physique, sur son propre ordinateur FIN. Scanne les conteneurs de son réseau FIN local, envoie les données à CENTRAL.
- **STOCKAGE_CENTRAL** : une unique instance, connectée au réseau FIN et à Internet. Reçoit toutes les données des satellites et push vers le serveur web.

Les conteneurs à surveiller se configurent dans `STOCKAGE_SATELLITE.lua` :

```lua
-- Classes de containers à découvrir (ajuster selon le jeu)
local CONTAINER_CLASSES = {
    "Build_StorageContainerMk2_C",
    "Build_StorageContainerMk1_C",
    "Build_IndustrialContainer_C",
}
-- Nick du computer FIN = identifiant du satellite dans le dashboard
```

Le nick du computer FIN sert d'identifiant : il apparaît dans le dashboard (section STOCKAGE > MISE À JOUR) et dans les logs GET_LOG (tag `SAT:NICK`).

Le mode scan rapide (2 s) s'active automatiquement si DISPATCH envoie un heartbeat sur le port 55 pour les buffers surveillés par ce satellite.

---

## Structure du repo

```
Ficsit-Networks-CMK/
├── fin/
│   ├── LOGGER.lua            Hub central trains + stockage
│   ├── LOGGER_EEPROM.lua     Bootloader LOGGER
│   ├── DISPATCH.lua          Dispatch intelligent multi-routes
│   ├── DISPATCH_EEPROM.lua   Bootloader DISPATCH (fetch config HTTP)
│   ├── STARTER.lua           Séquence ON/OFF + feu tricolore
│   ├── TRAIN_TAB.lua         Dashboard 3 écrans
│   ├── TRAIN_STATS.lua       Métriques réseau
│   ├── TRAIN_MAP.lua         Carte trains temps réel
│   ├── DETAIL.lua            Détail train + navigation
│   ├── GET_LOG.lua           Console logs réseau
│   ├── GETLOG_EEPROM.lua     Bootloader GET_LOG
│   ├── STOCKAGE_CENTRAL.lua  Hub stockage : reçoit satellites, push HTTP, poll commandes
│   ├── STOCKAGE_SATELLITE.lua Satellite stockage : scanne conteneurs FIN locaux
│   └── POWER_MON.lua         Moniteur réseau électrique
├── web/
│   ├── train_server.py       Flask + Discord bot
│   ├── index.html            Dashboard web
│   ├── overlay.html          Overlay OBS
│   ├── config.example.py     Template config
│   └── config.py             Config locale (ignoré git)
├── agent_docs/               Documentation technique interne
└── docs/
    ├── score-reseau.md       Détail du calcul de score
    └── inventaire-api.md     Référence API FIN utilisée
```

---

## Crédits

Projet Satisfactory personnel.
Code réalisé en collaboration avec **Claude (Anthropic)** — assistant IA ayant conçu et implémenté l'architecture réseau FIN, les algorithmes de dispatch, les calculs de stats, le serveur Python, le dashboard web et l'overlay OBS.
Direction fonctionnelle, tests en jeu et validation : le Guide du projet.

---
---

# English version

> **English documentation** — French version above / [Jump to French](#monitor-ficsit-network-by-cmk--satisfactory-train--storage-network)

Real-time monitoring system for a Satisfactory train network, built with **Ficsit-Networks (FIN)**.
Distributed architecture: multiple FIN computers communicate over a local network, push data to a Python server, and expose a web dashboard + OBS overlay.

> This project is developed with the assistance of **Claude (Anthropic)** — an AI that writes virtually all the Lua, Python and HTML/CSS/JS code based on functional requirements defined in the project guide.

---

## Overview

```
Satisfactory (FIN Lua)                         Local server (Python)            Browser / OBS
───────────────────────────────────────────    ─────────────────────────────    ──────────────────────
LOGGER  ─── FIN network ──▶ TRAIN_TAB          Flask :8081
        ─── FIN network ──▶ TRAIN_STATS        POST /api/push            ◀── LOGGER       index.html (dashboard)
        ─── FIN network ──▶ DETAIL             GET  /api/data            ──▶ browser      overlay.html (OBS)
        ─── HTTP POST ────▶ train_server       POST /api/trips           ◀── LOGGER
DISPATCH ── HTTP GET ─────▶ train_server       POST /api/stockage/central/push ◀── STOCKAGE_CENTRAL
POWER_MON ─ FIN network ──▶ LOGGER
STOCKAGE_SATELLITE (×N) ── FIN network (port 56/57) ──▶ STOCKAGE_CENTRAL ── HTTP POST ──▶ train_server
ALL ──────── FIN network ──▶ GET_LOG
```

---

## Project components

### FIN scripts (Lua) — `fin/`

| Script | FIN computer | Role |
|--------|--------------|------|
| `LOGGER.lua` | LOGGER | Central hub: monitors trains, computes all stats, pushes data to the web server |
| `DISPATCH.lua` | DISPATCH | Smart multi-route dispatch: decides GO/HOLD based on buffer levels, rewrites timetables |
| `STARTER.lua` | STARTER | Network start/stop sequence, animated traffic light, controls other computers |
| `TRAIN_TAB.lua` | TRAIN_TAB | 3-screen dashboard: stopped / moving / docked trains |
| `TRAIN_STATS.lua` | TRAIN_STATS | Network metrics screen (score, speed, confidence, history) |
| `TRAIN_MAP.lua` | TRAIN_MAP | Real-time train map with positions and stations |
| `DETAIL.lua` | DETAIL | Single train detail + navigation list (2 screens, button panel) |
| `GET_LOG.lua` | GET_LOG | Aggregates and displays all network logs for the session |
| `STOCKAGE_CENTRAL.lua` | STOCKAGE_CENTRAL | Storage hub: receives data from all satellites, aggregates, pushes to the web server. Polls web commands (reboot, fast mode) |
| `STOCKAGE_SATELLITE.lua` | SAT (×N) | Storage satellite: discovers local FIN containers, scans inventories, sends data to CENTRAL |
| `POWER_MON.lua` | POWER_MON | Monitors the power grid (production, consumption, capacity, batteries), sends to LOGGER |

**EEPROM scripts** (bootloaders): `LOGGER_EEPROM.lua`, `DISPATCH_EEPROM.lua`, `GETLOG_EEPROM.lua` — loaded first, they initialize the network before launching the main script.

**Debug scripts** (not deployed in production): `COMPSCAN.lua`, `LOCO_SCAN.lua`, `PANELSCAN.lua`, `SCREEN_PROBE.lua`

### Web server (Python) — `web/`

| File | Role |
|------|------|
| `train_server.py` | Flask server (port 8081) + Discord bot; receives data from LOGGER and DISPATCH, exposes a full REST API |
| `index.html` | Full web dashboard: trains, trips, stats, storage, dispatch, performance (draggable cards) |
| `overlay.html` | OBS/browser overlay: 3 skins (bottom ticker, top ticker, terminal) with train/storage carousel |
| `config.py` | Local configuration (Discord token, channel ID, title — **not committed**) |
| `config.example.py` | Configuration template |

---

## FIN network architecture

All communication between FIN computers uses **NetworkCard** via `net:broadcast()` (multicast) or `net:send()` (targeted point-to-point).
Universal rule: **every `print()` from every script is redirected to port 43** via broadcast to GET_LOG — never displayed locally.

```
Port 42  broadcast        Full trip (train, from, to, duration, inventory)          LOGGER → DETAIL
Port 43  broadcast        Text logs (script, message)                                ALL    → GET_LOG
Port 44  broadcast        Train state snapshot (serialized Lua table)                LOGGER → TRAIN_TAB, TRAIN_STATS, DISPATCH
Port 45  broadcast        ETA stats per segment (train, segment, avg, count)         LOGGER → DETAIL
Port 46  broadcast+send   LOGGER_ADDR beacon + WHO_IS_LOGGER handshake               LOGGER ↔ STOCKAGE
Port 47  broadcast        Computed stats (score, speed, confidence, history…)        LOGGER → TRAIN_STATS
Port 48  net:send         Storage data (zone, fill%, items, speed)                   STOCKAGE → LOGGER
Port 49  net:send         Point-to-point requests/responses (stats + storage)        ANY    → LOGGER
Port 50  broadcast        SHUTDOWN — shutdown signal for all computers               STARTER → ALL
Port 51  broadcast        Power grid stats (prod, cons, capacity, batteries)         POWER_MON → LOGGER
Port 55  broadcast+send   DISPATCH buffer priority (fast 2 s mode) + PRIORITY_REQUEST DISPATCH ↔ STOCKAGE
Port 56  net:send         Inventory scan data (serialized Lua table)                 SATELLITE → CENTRAL
Port 57  broadcast+send   Discovery + commands (SATELLITE_HERE, CENTRAL_ADDR, CONTAINERS_REPORT, REBOOT, FAST_MODE) SATELLITE ↔ CENTRAL
```

> **Note:** DISPATCH and STOCKAGE_CENTRAL both use an **InternetCard** to communicate with the Flask server (route config, data push, command polling).

---

## Detailed data flow

### 1. Train monitoring (LOGGER)

LOGGER is the **single source of truth for trains**. It queries the track graph via the `GARE_TEST` station every 2 seconds:

- Filters valid trains (master locomotive + timetable with stops > 0)
- Detects state changes (moving / docked / stopped)
- Records every complete trip (from, to, duration, inventory)
- Computes **all stats**: average speed, average duration, network score, confidence, history

**Broadcast port 44** → TRAIN_TAB, TRAIN_STATS, DISPATCH (state snapshot)
**Broadcast port 42** → DETAIL (full trip on trip completion)
**Broadcast port 47** → TRAIN_STATS (computed stats)
**HTTP POST /api/push** → Python server (full snapshot every 2 s)

### 2. Smart dispatch (DISPATCH)

DISPATCH manages delivery train assignments based on actual buffer levels.

**Startup:** the EEPROM fetches route configuration from Flask (`GET /api/dispatch/routes.lua`) before starting the main script.

**Decision cycle (every 2 s):**
1. Receives train snapshot from LOGGER via port 44
2. Receives storage data from STOCKAGE via port 55 (fast mode)
3. For each configured route:
   - **HOLD** if buffer is not sufficiently stocked: timetable cleared + `setSelfDriving(false)` → train held at PARK station
   - **GO** if buffer is sufficient: timetable rewritten `[PARK → DELIVERY]` + `setSelfDriving(true)` → train dispatched
   - **URGENCY** if slots ≤ MIN_BUF_SLOTS: priority GO forced
4. Limits `MAX_EN_ROUTE` trains simultaneously in delivery per route
5. Heartbeat on port 55 → activates fast scan (2 s) on watched buffers in STOCKAGE

**Remote commands:** Flask exposes `GET/POST /api/dispatch/command` — allows forcing GO/HOLD/AUTO from the web dashboard.

**Dispatch report:** web modal with full decision history (GO/HOLD, reason, timestamp) via `GET /api/dispatch/report`.

### 3. Network score

The score (0–100) is computed by LOGGER alone on two axes:

- **Mobility (60%)**: proportion of trains currently moving
- **Consistency (40%)**: regularity of trip durations (coefficient of variation)

**Confidence** reflects score reliability: mobility (50%), trip count (30%), LOGGER uptime (20%). Result: HIGH / GOOD / LOW / NONE.

### 4. Storage (SATELLITE → CENTRAL → Flask)

Distributed two-level architecture:

**STOCKAGE_SATELLITE** (one instance per physical zone):
1. On boot, broadcasts port 57 `SATELLITE_HERE` + NICK → CENTRAL replies with its address
2. Scans local FIN containers on schedule: **60 s** (normal) or **2 s** (fast, when DISPATCH watches these buffers)
3. Sends data via `net:send(centralAddr, 56, …)`: fill%, items, slots, per-container detail, script `version`
4. Auto-reverts to normal mode if no CENTRAL heartbeat for `FAST_EXPIRY` seconds

**STOCKAGE_CENTRAL** (one instance):
1. Receives data from all satellites on port 56 and aggregates it
2. Pushes to Flask (`POST /api/stockage/central/push`) on each scan received
3. Polls Flask every 5 s (`POST /api/stockage/central/command.lua`) for web commands
4. Relays REBOOT / FAST_MODE commands to satellites via `net:send` port 57

### 5. Power monitoring (POWER_MON → LOGGER)

`POWER_MON.lua` monitors the main power circuit and broadcasts on port 51: production, consumption, total capacity, battery state. LOGGER includes this data in the HTTP push.

### 6. Python server (Flask)

```
POST /api/push                          → full snapshot from LOGGER (trains, stats, storage, power)
POST /api/trips                         → trip history
GET  /api/data                          → full data for the browser (includes satellite_versions, sat_update_results, sat_latest_version)
POST /api/stockage-order                → save storage card order (persisted)
POST /api/stockage-purge                → manually remove inactive zones
GET  /api/dispatch/routes               → DISPATCH route configuration (JSON)
GET  /api/dispatch/routes.lua           → route config in Lua format (for EEPROM)
PUT  /api/dispatch/routes               → update route configuration
GET  /api/dispatch/command              → pending command for DISPATCH
POST /api/dispatch/command              → push a command (GO/HOLD/AUTO)
GET  /api/dispatch/report               → DISPATCH decision history
GET  /api/perf/trains                   → "Check Perf" analysis: top 10 least useful trains (scored by time window)
GET  /api/logs                          → raw network logs (15 000-entry ring buffer)
POST /api/stockage/central/push         → CENTRAL → Flask: aggregated data + satellite list (with versions)
POST /api/stockage/central/command.lua  → CENTRAL polls pending command (Lua format, 60 s timeout)
POST /api/stockage/satellite/reboot     → Dashboard → Flask: trigger sequential satellite reboot(s)
```

**Log retention:** 15 000-entry in-memory ring buffer (~1 h at full rate), persisted to disk across restarts.

**Storage TTL:** zones without an update for more than 10 minutes are silently removed on the next `/api/data`.

The Discord bot (same process) periodically edits an embed in a configured channel, without triggering a notification.

---

## Web dashboard (`index.html`)

### TRAINS section

Tabs:
- **List**: real-time status of each train (status, speed, position)
- **Statistics**: colour-coded score, confidence, average speed/duration, score histogram
- **Check Perf**: analysis of the least useful trains over a selectable window (15 min / 30 min / 1 h) — score based on empty trips, frequency, and load per wagon

### DISPATCH section

- Route table with GO/HOLD state, buffer level, trains in transit
- **Report** button: decision history modal with timestamps and reasons
- Manual commands from the UI (force GO/HOLD/AUTO)

### STORAGE section

3 tabs:

**INFO:**
- Draggable cards (native HTML5 drag & drop) per zone, order persisted server-side
- Colour-coded fill indicator (green → yellow → red)
- Reduced opacity if zone is inactive (server_ts > 120 s)
- Detail modal: all items, slots, per-container breakdown
- Toggle between summary view and detailed view

**CONFIGURATION:**
- Per-satellite settings: item filters, sticky pool, collapsed zones, search

**UPDATE:**
- Version tracking per satellite (running version vs reference version in the repository)
- "Obsolete" badge (red) if a satellite runs an older version
- "Update" button per satellite or "Update all" (sequential reboot)
- "Outdated" filter button: shows only out-of-date satellites (does not trigger a reboot)

---

## OBS Overlay (`overlay.html`)

3 selectable skins (via buttons or `?skin=` URL parameter):

| Skin | Description |
|------|-------------|
| `ticker` | Thin band at the bottom of the screen |
| `ticker-top` | Thin band at the top of the screen |
| `terminal` | Compact industrial-monitor-style panel (top-right corner) |

**Auto carousel (ticker skins):** rotates every 7 s between trains, score/stats and storage zones.

**URL parameters:**
```
overlay.html?skin=ticker-top   → top ticker
overlay.html?obs=1             → hide skin selector (OBS mode)
overlay.html?alpha=0.8         → border opacity (default: 0.45)
```

---

## Installation

### Requirements
- Satisfactory + **Ficsit-Networks (FIN)** mod
- Python 3.10+ with `flask` and `discord.py`

### Setup

```bash
git clone https://github.com/CaMaK/Ficsit-Networks-CMK.git
cd web
cp config.example.py config.py
# Edit config.py: BOT_TOKEN, CHANNEL_ID, SITE_TITLE
pip install flask discord.py
python train_server.py
```

### In-game (FIN)

1. Place a FIN computer for each script, wire NetworkCard + required components
2. Name components according to script constants (e.g. `GARE_TEST`, `TAB_SCREEN_L`, `TRAFFIC_POLE`…)
3. If an EEPROM script exists for the computer, load it first, then the main script
4. Start scripts — LOGGER last to avoid discovery timeouts

### Required in-game components

| In-game name | Used by | Type |
|--------------|---------|------|
| `GARE_TEST` | LOGGER, DETAIL | Station (for `getTrackGraph()`) |
| `TAB_SCREEN_L/C/R` | TRAIN_TAB | 3× GPU T2 + screens |
| `STATS_SCREEN` | TRAIN_STATS | GPU T2 + screen |
| `DETAIL_SCREEN_R/L` | DETAIL | 2× GPU T2 + screens |
| `DETAIL_PANEL2` | DETAIL | Modular panel with buttons `(4,8)` left, `(6,8)` right, LED `(5,8)` |
| `MAP_SCREEN` | GET_LOG | GPU T2 + screen |
| `TRAINMAP_SCREEN` | TRAIN_MAP | GPU T2 + screen |
| `POWER_SCREEN` | POWER_MON | GPU T2 + screen |
| `TRAFFIC_POLE` | TRAIN_TAB | Modular pole with LEDs (green x=0, yellow x=1, red x=2) |
| `TRAFFIC_SPEAKER` | TRAIN_TAB | Speaker pole for custom sounds |
| `PANEL_L` | STARTER | Main panel with switches `(2,6)` and `(8,6)` |
| `POWER_POLE` | POWER_MON | Power component (configurable nick in POWER_MON) |
| `STOCKAGE_1`, `STOCKAGE_2`… | STOCKAGE | MK2 containers (names configurable in `STOCKAGE.lua`) |

---

## STOCKAGE configuration — SATELLITE/CENTRAL architecture

The storage system is distributed across two levels:

- **STOCKAGE_SATELLITE**: one instance per physical zone, on its own FIN computer. Scans the FIN containers on its local network, sends data to CENTRAL.
- **STOCKAGE_CENTRAL**: a single instance, connected to both the FIN network and the Internet. Receives data from all satellites and pushes it to the web server.

Containers to monitor are configured in `STOCKAGE_SATELLITE.lua`:

```lua
-- Container classes to discover (adjust per game)
local CONTAINER_CLASSES = {
    "Build_StorageContainerMk2_C",
    "Build_StorageContainerMk1_C",
    "Build_IndustrialContainer_C",
}
-- FIN computer nick = satellite identifier in the dashboard
```

The FIN computer nick is used as the satellite's identifier: it appears in the dashboard (STORAGE > UPDATE tab) and in GET_LOG logs (tag `SAT:NICK`).

Fast scan mode (2 s) activates automatically when DISPATCH sends a heartbeat on port 55 for buffers watched by that satellite.

---

## Repository structure

```
Ficsit-Networks-CMK/
├── fin/
│   ├── LOGGER.lua            Train + storage central hub
│   ├── LOGGER_EEPROM.lua     LOGGER bootloader
│   ├── DISPATCH.lua          Smart multi-route dispatch
│   ├── DISPATCH_EEPROM.lua   DISPATCH bootloader (HTTP config fetch)
│   ├── STARTER.lua           ON/OFF sequence + traffic light
│   ├── TRAIN_TAB.lua         3-screen dashboard
│   ├── TRAIN_STATS.lua       Network metrics
│   ├── TRAIN_MAP.lua         Real-time train map
│   ├── DETAIL.lua            Train detail + navigation
│   ├── GET_LOG.lua           Network log console
│   ├── GETLOG_EEPROM.lua     GET_LOG bootloader
│   ├── STOCKAGE_CENTRAL.lua  Storage hub: receives satellites, HTTP push, polls commands
│   ├── STOCKAGE_SATELLITE.lua Storage satellite: scans local FIN containers
│   └── POWER_MON.lua         Power grid monitor
├── web/
│   ├── train_server.py       Flask + Discord bot
│   ├── index.html            Web dashboard
│   ├── overlay.html          OBS overlay
│   ├── config.example.py     Config template
│   └── config.py             Local config (git-ignored)
├── agent_docs/               Internal technical documentation
└── docs/
    ├── score-reseau.md       Network score calculation details
    └── inventaire-api.md     FIN API reference
```

---

## Credits

Personal Satisfactory project.
Code built in collaboration with **Claude (Anthropic)** — an AI assistant that designed and implemented the FIN network architecture, dispatch algorithms, stats calculations, the Python server, the web dashboard and the OBS overlay.
Functional direction, in-game testing and validation: the project guide.
