#!/bin/bash
# Script para detectar secretos accidentales antes del commit
# Previene commits con API keys, tokens, contraseñas, etc.

set -e

echo "🔍 Verificando archivos por posibles secretos..."

# Patrones de secretos a buscar
PATTERNS=(
  # API Keys genéricas
  'api[_-]?key["\s]*[:=]["\s]*["\047][a-zA-Z0-9_-]{20,}'
  'apikey["\s]*[:=]["\s]*["\047][a-zA-Z0-9_-]{20,}'

  # Google API Keys
  'AIza[0-9A-Za-z_-]{35}'

  # AWS
  'AKIA[0-9A-Z]{16}'
  'aws[_-]?secret[_-]?access[_-]?key'

  # Tokens genéricos
  'token["\s]*[:=]["\s]*["\047][a-zA-Z0-9_-]{20,}'
  'bearer["\s]+[a-zA-Z0-9_-]{20,}'

  # Passwords
  'password["\s]*[:=]["\s]*["\047][^"\047]{8,}'

  # Private keys
  '-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----'

  # Supabase (solo si están hardcodeadas, no en .env)
  'eyJ[a-zA-Z0-9_-]{100,}'

  # Conexiones de base de datos
  'postgres://[^"\s]+'
  'mysql://[^"\s]+'
  'mongodb(\+srv)?://[^"\s]+'
)

# Archivos a excluir de la verificación
EXCLUDE_PATTERNS=(
  "*.lock"
  "*.test.*"
  "*.spec.*"
  "*.md"
  ".env.example"
  "check-secrets.sh"
  "node_modules/*"
  "dist/*"
  "coverage/*"
  ".git/*"
)

# Construir el comando de exclusión
EXCLUDE_ARGS=""
for pattern in "${EXCLUDE_PATTERNS[@]}"; do
  EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude=$pattern"
done

# Obtener archivos staged para commit
STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || echo "")

if [ -z "$STAGED_FILES" ]; then
  echo "✅ No hay archivos staged para verificar"
  exit 0
fi

FOUND_SECRETS=0

for pattern in "${PATTERNS[@]}"; do
  # Buscar en archivos staged
  MATCHES=$(echo "$STAGED_FILES" | xargs grep -l -E -i "$pattern" $EXCLUDE_ARGS 2>/dev/null || true)

  if [ -n "$MATCHES" ]; then
    echo ""
    echo "⚠️  Posible secreto encontrado (patrón: $pattern):"
    echo "$MATCHES" | while read file; do
      echo "   📄 $file"
      # Mostrar la línea (sin el valor del secreto)
      grep -n -E -i "$pattern" "$file" 2>/dev/null | head -3 | sed 's/\(.\{50\}\).*/\1.../' | while read line; do
        echo "      $line"
      done
    done
    FOUND_SECRETS=1
  fi
done

if [ $FOUND_SECRETS -eq 1 ]; then
  echo ""
  echo "❌ Se encontraron posibles secretos en los archivos staged."
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

echo "✅ No se encontraron secretos en los archivos staged"
exit 0
