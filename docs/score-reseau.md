# Score Réseau (0–100)

Calculé toutes les 60s dans `broadcastStats()` via `calcScore()`.

Composé de 3 facteurs pondérés :

| Facteur      | Poids | Calcul                                                                 |
|--------------|-------|------------------------------------------------------------------------|
| Mobilité     | 40 %  | trains en mouvement / total trains                                     |
| Régularité   | 35 %  | snapshots reçus / snapshots attendus depuis le boot                    |
| Consistance  | 25 %  | Inverse du coefficient de variation des durées de trajets              |

**Mobilité** : si 3 trains sur 5 roulent → 0.60

**Régularité** : STATS reçoit un snapshot port 44 toutes les 2s. Si l'uptime est 100s, on attend 50 snapshots. Si on en a reçu 45 → 0.90

**Consistance** : si tous les trajets durent ~3min → 1.0. Si certains durent 1min et d'autres 10min (CV élevé) → score bas

---

# Confiance

Calculée depuis les métriques de performance (vitesse + durée moyenne), **pas** depuis le score.

Indique à quel point les stats sont fiables compte tenu des conditions réseau :

| Composant              | Logique                                                                 |
|------------------------|-------------------------------------------------------------------------|
| `sScore`               | Vitesse moy / 150 km/h (capped à 1.0)                                  |
| `tScore`               | 1.0 si trajet ≤ 2min, 0.0 si ≥ 10min, linéaire entre les deux          |
| `c = (sScore+tScore)/2`| Score combiné                                                           |

| c       | Label                  |
|---------|------------------------|
| ≥ 0.80  | EXCELLENTE (vert)      |
| ≥ 0.60  | BONNE (vert)           |
| ≥ 0.40  | CORRECTE (jaune)       |
| ≥ 0.20  | DÉGRADÉE (rouge)       |
| < 0.20  | MAUVAISE (rouge)       |

**Exemple** : vitesse moy 120 km/h → sScore=0.80, trajet moy 4min → tScore=0.77, c=0.78 → BONNE

---

> **Note** : Score et Confiance mesurent des choses différentes.
> Le **score** mesure l'activité du réseau.
> La **confiance** mesure la qualité des trajets (trains rapides sur de courts segments = bonne confiance).
