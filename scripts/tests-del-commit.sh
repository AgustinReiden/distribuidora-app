#!/bin/bash
# Tests del pre-commit (#1587, decisión D60 del dueño): el commit corre sólo los tests
# RELACIONADOS con lo que cambió; la suite entera la corre el CI (job `test` de ci.yml, con
# cobertura). La suite entera tarda ~11 min (20 o más con la máquina cargada) y en cada corrida
# se caía un test distinto por tiempo; el commit se abortaba con el turno de lo pesado tomado.
#
#   bash scripts/tests-del-commit.sh        # lo que hay en el índice (git add)
#   npm run test:commit                     # lo mismo
#
# Qué corre:
#  1. `vitest related` sobre lo que está en el índice: los tests que importan (directa o
#     transitivamente) cada archivo cambiado, y los propios tests que cambiaron.
#  2. SIEMPRE los tests que leen el árbol del repo desde el disco (los trinquetes y los
#     contratos: erroresCrudos, grantsRest, migracionesNumeroUnico…). No importan el archivo
#     que vigilan, así que `related` no los ve, y son justo los que atajan lo que nadie
#     pensó en testear. Se buscan con grep, no hay lista que se pudra.
#  3. La suite ENTERA si el cambio mueve a todos los tests: una versión de package.json (una
#     dependencia), el lockfile, la config de vite/vitest/ts o el setup de los tests.
set -e

# Todo lo que cambia el índice, bajas incluidas: un commit que sólo borra archivos también corre los tests que leen el árbol
# (los trinquetes y contratos son justo los que atajan un borrado).
CAMBIADOS=$(git diff --cached --name-only)

if [ -z "$CAMBIADOS" ]; then
  echo "Tests del commit: nada en el índice, no hay nada que correr."
  exit 0
fi

SUITE_ENTERA=0
if echo "$CAMBIADOS" | grep -qE '^(package-lock\.json|vite\.config\.[jt]s|vitest\.[^/]+|tsconfig[^/]*\.json|src/test/setup\.[jt]s|src/test/stubs/)'; then
  SUITE_ENTERA=1
fi
# package.json: sólo si se tocó una versión (dependencias); sumar un script no mueve a ningún test.
if echo "$CAMBIADOS" | grep -qx 'package.json' && git diff --cached -U0 package.json | grep -qE '^[+-][[:space:]]+"[^"]+":[[:space:]]+"[~^]?[0-9]'; then
  SUITE_ENTERA=1
fi
if [ "$SUITE_ENTERA" = 1 ]; then
  echo "Tests del commit: cambió la config, el setup de los tests o una dependencia -> suite entera."
  exec npm run test:run
fi

# Tests que leen archivos del repo desde el disco (fs, import.meta.glob, ?raw).
LECTORES=$(grep -rlE "readdirSync|readFileSync|globSync|from 'node:fs'|from \"node:fs\"|from 'fs'|from \"fs\"|import\.meta\.glob|\?raw" src \
  --include='*.test.ts' --include='*.test.tsx' --include='*.test.js' --include='*.test.jsx' || true)

# A `vitest related` van sólo los archivos que existen (un borrado ya no está en el árbol), uno por argumento: una ruta con
# espacios no se parte.
ARGS=()
while IFS= read -r f; do
  if [ -n "$f" ] && [ -e "$f" ]; then ARGS+=("$f"); fi
done <<< "$CAMBIADOS"
while IFS= read -r f; do
  if [ -n "$f" ]; then ARGS+=("$f"); fi
done <<< "$LECTORES"

echo "Tests del commit: los relacionados con $(echo "$CAMBIADOS" | wc -l | tr -d ' ') archivo(s) del índice + $(echo "$LECTORES" | grep -c . || true) que leen el árbol. La suite entera corre en el CI."

npx vitest related --run --passWithNoTests "${ARGS[@]}"
