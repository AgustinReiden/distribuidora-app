#!/bin/bash
# Script para detectar secretos accidentales antes del commit
# Previene commits con API keys, tokens, contraseñas, etc.

set -e

echo "🔍 Verificando archivos por posibles secretos..."

# Patrones de secretos a buscar (grep -E -i).
#
# Los genéricos (api key, token, password, bearer) NO matcheaban nada hasta
# #1600 (1600-b2): estaban escritos con `\s` y `'` DENTRO de una lista
# `[...]`, donde grep -E los toma como la barra, la «s» y el 0, 4 y 7 literales.
# Ahora usan `[:space:]` y la comilla simple se arma aparte (Q).
Q="'"
PATTERNS=(
  # API Keys genéricas
  "api[_-]?key[\"${Q}[:space:]]*[:=][\"${Q}[:space:]]*[\"${Q}][a-zA-Z0-9_-]{20,}"
  "apikey[\"${Q}[:space:]]*[:=][\"${Q}[:space:]]*[\"${Q}][a-zA-Z0-9_-]{20,}"

  # Google API Keys
  'AIza[0-9A-Za-z_-]{35}'

  # AWS
  'AKIA[0-9A-Z]{16}'
  'aws[_-]?secret[_-]?access[_-]?key'

  # Tokens genéricos
  "token[\"${Q}[:space:]]*[:=][\"${Q}[:space:]]*[\"${Q}][a-zA-Z0-9_-]{20,}"
  # Con al menos un dígito: un token real los lleva, y «Bearer jwt-de-prueba» de un test no.
  'bearer[[:space:]]+[a-zA-Z_.-]*[0-9][a-zA-Z0-9_.-]{19,}'

  # Passwords
  "password[\"${Q}[:space:]]*[:=][\"${Q}[:space:]]*[\"${Q}][^\"${Q}]{8,}"

  # Private keys
  '-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----'

  # Supabase (solo si están hardcodeadas, no en .env)
  'eyJ[a-zA-Z0-9_-]{100,}'

  # Conexiones de base de datos
  'postgres(ql)?://[^:/@[:space:]]+:[^@[:space:]]+@'
  'mysql://[^"[:space:]]+'
  'mongodb(\+srv)?://[^"[:space:]]+'
)

# Archivos a excluir de la verificación.
#
# *.test.* / *.spec.* y *.md NO están acá a propósito: excluirlos por patrón
# dejaba sin chequear justo los lugares donde un secreto real es más fácil de
# pegar sin querer (un token de prueba copiado de un .env real, un ejemplo con
# una key real en la documentación). Un falso positivo puntual se resuelve
# agregando el archivo a ALLOWLIST_FILES, no reabriendo el agujero para todos.
EXCLUDE_PATTERNS=(
  "*.lock"
  ".env.example"
  "check-secrets.sh"
  "node_modules/*"
  "dist/*"
  "coverage/*"
  ".git/*"
)

# Archivos con falsos positivos conocidos y ya revisados a mano. Cada entrada
# necesita el motivo al lado: esto es una lista de excepciones, no un lugar
# para silenciar lo que no se llegó a mirar.
ALLOWLIST_FILES=(
  # Google API key documentada en un audit report ya cerrado: la
  # recomendación del propio hallazgo (rotarla) ya se aplicó; queda como
  # registro histórico de qué se encontró y cuándo.
  "docs/archive/2026-01-20-AUDIT_REPORT.md"
  # Connection string de ejemplo con placeholders (<proj-ref>, <password>),
  # no una credencial real.
  "scripts/export-tp-export-dump.md"
  # Connection strings de documentación con el password como placeholder (<password>,
  # PASSWORD, pw): el chequeo ahora mira también `postgresql://` (1600-b2) y esos
  # cinco archivos lo traen a propósito para mostrar el formato.
  "migrations/README.md"
  "scripts/backup/restore-runbook.md"
  "scripts/backup/setup.md"
  "scripts/backup/windows/config.example.json"
  "scripts/concurrencia/README.md"
  # La cabecera `-----BEGIN PRIVATE KEY-----` de un PEM como texto: el código la saca con
  # un replace antes de decodificar la clave que llega por secret, y el test arma un PEM
  # falso (base64 de relleno). El patrón de private key ahora sí se evalúa (le faltaba
  # `-e` y grep lo tomaba por una opción, 1600-b2); estas dos no traen ninguna clave.
  "supabase/functions/optimizar-ruta/sa-auth.ts"
  "supabase/functions/tests/optimizar_ruta_ventanas.test.ts"
)

# Construir el comando de exclusión
EXCLUDE_ARGS=""
for pattern in "${EXCLUDE_PATTERNS[@]}"; do
  EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude=$pattern"
done

# Qué archivos se miran:
#   (sin argumentos)  los staged: es el pre-commit.
#   --all             todos los versionados (`git ls-files`): es el CI.
# En CI el índice está vacío (`git diff --cached` no da nada), así que hasta
# #1600 (1600-b2) el paso «Check for secrets in code» no revisaba un solo archivo
# y salía verde. Con CI=true (GitHub Actions) el modo es --all aunque no se lo pidan.
MODO="staged"
if [ "${1:-}" = "--all" ] || [ -n "${CI:-}" ]; then
  MODO="all"
fi

if [ "$MODO" = "all" ]; then
  echo "(modo --all: todos los archivos versionados)"
  STAGED_FILES=$(git -c core.quotepath=false ls-files 2>/dev/null || echo "")
  if [ -z "$STAGED_FILES" ]; then
    echo "❌ No se pudo listar los archivos versionados: el chequeo no puede mirar."
    exit 2
  fi
else
  STAGED_FILES=$(git -c core.quotepath=false diff --cached --name-only --diff-filter=ACMR 2>/dev/null || echo "")
fi

# Sacar los de la allowlist antes de chequear nada.
for allowed in "${ALLOWLIST_FILES[@]}"; do
  STAGED_FILES=$(echo "$STAGED_FILES" | grep -v -F -x "$allowed" || true)
done

if [ -z "$STAGED_FILES" ]; then
  echo "✅ No hay archivos staged para verificar"
  exit 0
fi

FOUND_SECRETS=0

# Una sola pasada con todos los patrones: en --all son miles de archivos y una pasada
# por patrón tardaba más de 18 minutos en Windows. Si nada matchea, no hay más que hacer;
# si algo matchea, abajo se recorre patrón por patrón para decir cuál y dónde.
TODOS=()
for pattern in "${PATTERNS[@]}"; do
  TODOS+=(-e "$pattern")
done
HAY=$(echo "$STAGED_FILES" | tr '\n' '\0' | xargs -0 grep -I -l -E -i "${TODOS[@]}" $EXCLUDE_ARGS 2>/dev/null || true)
if [ -z "$HAY" ]; then
  if [ "$MODO" = "all" ]; then
    echo "✅ No se encontraron secretos en los archivos versionados"
  else
    echo "✅ No se encontraron secretos en los archivos staged"
  fi
  exit 0
fi

for pattern in "${PATTERNS[@]}"; do
  # Buscar en los archivos que matchearon algo
  MATCHES=$(echo "$HAY" | tr '\n' '\0' | xargs -0 grep -I -l -E -i -e "$pattern" $EXCLUDE_ARGS 2>/dev/null || true)

  if [ -n "$MATCHES" ]; then
    echo ""
    echo "⚠️  Posible secreto encontrado (patrón: $pattern):"
    echo "$MATCHES" | while IFS= read -r file; do
      echo "   📄 $file"
      # Mostrar la línea (sin el valor del secreto)
      grep -I -n -E -i -e "$pattern" "$file" 2>/dev/null | head -3 | sed 's/\(.\{50\}\).*/\1.../' | while read line; do
        echo "      $line"
      done
    done
    FOUND_SECRETS=1
  fi
done

if [ $FOUND_SECRETS -eq 1 ]; then
  echo ""
  echo "❌ Se encontraron posibles secretos en los archivos revisados."
  echo ""
  echo "Por favor:"
  echo "  1. Mueve los secretos a variables de entorno (.env)"
  echo "  2. Asegúrate de que .env esté en .gitignore"
  echo "  3. Usa VITE_* para variables del cliente"
  echo ""
  echo "Para saltear esta verificación (NO RECOMENDADO):"
  echo "  git commit --no-verify"
  echo ""
  exit 1
fi

echo "✅ No se encontraron secretos en los archivos revisados"
exit 0
