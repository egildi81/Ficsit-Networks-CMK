# API Inventaire FIN — Conteneur industriel

Découverte par exploration en jeu (Build_StorageContainerMk1_C).

## Pattern complet

```lua
local inv = component.proxy(component.findComponent("NICKNAME")[1]):getInventories()[1]

print("Slots:", inv.size, "| Items total:", inv.itemCount)
for i = 0, inv.size-1 do
    local s = inv:getStack(i)
    if s.count > 0 then
        print(string.format("  [%d] %d x %s (%s)", i, s.count, s.item.type.name, s.item.type.internalName))
    end
end
```

## Référence API

| Accès | Type | Description |
|-------|------|-------------|
| `component.findComponent("NICK")` | `Array<UUID>` | Trouve par nickname → retourne des UUIDs (pas des proxies) |
| `component.proxy(uuid)` | Proxy | Convertit un UUID en objet utilisable |
| `box:getInventories()` | `Array<Inventory>` | Liste des inventaires du composant (index 1 = principal) |
| `inv.size` | Int | Nombre de slots |
| `inv.itemCount` | Int | Total d'items dans l'inventaire |
| `inv:getStack(i)` | `Struct<ItemStack>` | Stack au slot i (0-indexé) |
| `stack.count` | Int | Quantité (0 si slot vide) |
| `stack.item.type.name` | String | Nom affiché (ex: `"Quartz brut"`) |
| `stack.item.type.internalName` | String | ID interne (ex: `"Desc_RawQuartz_C"`) |

## Pièges

- `findComponent()` retourne des **UUIDs** (strings), pas des proxies → toujours passer par `component.proxy()`
- `inv:getSize()` n'existe pas → utiliser `inv.size` (propriété)
- `stack.amount` n'existe pas → utiliser `stack.count`
- `stack.item.name` est nil sur un slot vide → tester `stack.count > 0` avant
- `getMethods()` ne fonctionne pas sur Inventory ni ItemStack → utiliser `getProperties()` pour explorer
