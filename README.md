# ⚡ Oracle Hub — sistema universal de scripts para Roblox

Un solo script universal que **detecta el juego** y carga automáticamente
el script correcto desde GitHub raw.

## Ejecutar (una línea en tu executor)

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/TU-USUARIO/oracle-hub/main/loader.luau"))()
```

(cambia `TU-USUARIO` por tu usuario de GitHub)

## Estructura

```
oracle-hub/
├── loader.luau               ← el universal (punto de entrada)
├── index.json                ← manifiesto: placeId → script
└── games/
    └── 110527353762049.luau  ← Oracle Trader (Bolsa de Valores de Roblox 2)
```

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

3. Listo — el universal lo detectará solo en ese juego; en otros juegos
   abrirá el menú con todos los scripts disponibles.

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

## Subir a GitHub

1. Crea un repo **público** llamado `oracle-hub` (con README).
2. Sube `loader.luau`, `index.json` y la carpeta `games/` respetando la estructura.
3. Edita la línea `REPO = ...` de `loader.luau` con tu usuario.
4. Pega el one-liner en tu executor y listo.
