# ⚡ Oracle Hub — sistema universal de scripts para Roblox

Un solo script universal que **detecta el juego** y carga automáticamente
el script correcto desde GitHub raw. Un hub, muchos juegos.

## Ejecutar (una línea en tu executor)

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/yadieldanger/oracle-hub/main/loader.luau"))()
```

## Estructura

```
oracle-hub/
├── loader.luau    ← el universal (punto de entrada, multi-juego)
├── index.json     ← manifiesto: placeId → script
└── games/
    └── <placeId>.luau  ← un archivo por juego
```

## Juegos en el hub

| Juego | Script |
|---|---|
| Bolsa de Valores de Roblox 2 | `games/110527353762049.luau` (Oracle Trader) |

## Cómo añadir un juego nuevo

1. Crea `games/<placeId>.luau` con tu script.
2. Añade una entrada en `index.json`:

```json
{
  "id": "<placeId>",
  "gameId": "<gameId opcional>",
  "name": "Nombre del juego",
  "script": "games/<placeId>.luau",
  "version": "1.0.0",
  "description": "Qué hace"
}
```

3. `git add -A && git commit -m "nuevo juego" && git push` — los clientes lo
   reciben automáticamente al ejecutar la misma línea.

## Contrato de los scripts de juego

- Al terminar, registran su teardown:
  `getgenv()._HUB_SCRIPT_STOP = function() ... end`
- El loader lo llama automáticamente antes de cargar otro script.
- Pueden leer `getgenv()._HUB_CONTEXT` (placeId, gameId, gameName, repo…).

## Config opcional (antes de ejecutar)

```lua
getgenv().ORACLE_HUB_REPO  = "https://raw.githubusercontent.com/otro/repo/main"
getgenv().ORACLE_HUB_INDEX_OVERRIDE = { ... }   -- dev: manifiesto en memoria
getgenv().ORACLE_HUB_LOCAL_GAME = "ruta.luau"   -- dev: carga el script desde disco
```

## Notas técnicas

- Cache-busting en cada fetch (`?t=…`): los clientes siempre reciben la
  última versión al reejecutar.
- Teardown en cadena: nunca quedan dos scripts de juego vivos.
- Sin dependencias: el menú del hub es GUI propia (Instance.new).
