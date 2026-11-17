#!/bin/bash
# Escanea el volcado del esquema antes de guardarlo en el cache de Actions: la foto es PUBLICA (la restaura
# cualquier PR, incluidos los de forks, y puede imprimirla en un log). Aborta (exit 1) si trae claves, tokens,
# URLs, correos, CUIT o teléfonos, y NO imprime lo que encontró. Uso: bash scripts/ci/escanear-volcado.sh <esquema.sql>
set -euo pipefail
f="$1"
malo=0
chequear() {
  n=$(grep -c -i -E "$2" "$f" || true)
  if [ "$n" -gt 0 ]; then
    echo "::error::El volcado trae $n linea(s) con $1: se aborta sin guardar la foto (no se imprime el contenido: el log es publico)."
    malo=1
  fi
}
chequear "una clave o un token" 'sb_secret_|ghp_[A-Za-z0-9]|github_pat_|sk_live_|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{50,}|BEGIN [A-Z ]*PRIVATE KEY|[0-9]{8,10}:[A-Za-z0-9_-]{35}'
chequear "una URL" 'https?://'
chequear "un correo" '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}'
chequear "un CUIT" '\b(20|23|24|27|30|33|34)-?[0-9]{8}-?[0-9]\b'
chequear "un telefono" '(\+54|\b0?[0-9]{2,4}[ -]?15[ -]?)[0-9]{6,8}'
[ "$malo" -eq 0 ]
echo "el volcado no trae claves, URLs, correos, CUIT ni telefonos"
