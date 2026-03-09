# Score Réseau (0–100)

Calculé dans `computeStats()` de LOGGER.lua, mis à jour toutes les 60s dans `scoreHistory`.

Composé de 2 facteurs pondérés :

| Facteur      | Poids | Calcul                                                        |
|--------------|-------|---------------------------------------------------------------|
| Mobilité     | 60 %  | `movingCnt / totalCnt` (trains en mouvement / total)         |
| Consistance  | 40 %  | `max(0, 1 - CV × 1.5)` (inverse du coef. de variation)      |

```lua
local score = math.floor((mobility*0.60 + consistency*0.40)*100)
```

**Mobilité** : si 3 trains sur 5 roulent → 0.60 → contribue 36 pts

**Consistance** : CV = écart-type / moyenne des durées de trajets.
Si tous les trajets durent ~3min → CV≈0 → consistency=1.0.
Si durées très variables → CV élevé → score bas. Capped à 0.

---

# Confiance

**Mesure la fiabilité des données qui alimentent le Score.**
Répond à : *"peut-on faire confiance au score affiché ?"*

| Composant      | Poids | Logique                                          |
|----------------|-------|--------------------------------------------------|
| `mobilityConf` | 50 %  | `min(movingCnt/totalCnt / 0.8, 1.0)` — 80% en mouvement = max |
| `sampleConf`   | 30 %  | `min(durCnt / 80, 1.0)` — 80 trajets = fiable   |
| `uptimeConf`   | 20 %  | `min(uptime / 300, 1.0)` — 5min de recul        |

```lua
local c = mobilityConf*0.50 + sampleConf*0.30 + uptimeConf*0.20
```

| c       | Label         |
|---------|---------------|
| ≥ 0.80  | HAUTE         |
| ≥ 0.60  | BONNE         |
| ≥ 0.40  | FAIBLE        |
| < 0.40  | INEXISTANTE   |

**Exemple** : 40 trajets + 3/5 trains en mouvement + 2min uptime
→ `0.6*0.5 + 0.5*0.3 + 0.4*0.2 = 0.53` → **FAIBLE** (score à prendre avec recul)

---

> **Note** : Score et Confiance mesurent des choses différentes.
> Le **score** mesure l'état du réseau (mobilité + régularité des trajets).
> La **confiance** mesure si les données sont suffisantes pour que ce score soit représentatif.
