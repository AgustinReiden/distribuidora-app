import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

/**
 * Los ensayos de SQL (scripts/test-*.sql) arman sus datos con el día ARGENTINO, no con el del servidor (B13d, #1603).
 *
 * La base corre en UTC: entre las 21 y las 24 de Argentina `CURRENT_DATE` ya es mañana, y un ensayo que le manda al
 * sistema esa fecha como «hoy» recibe un rechazo de fecha futura (el sistema mide con `_tablero_hoy()`, la regla de
 * CLAUDE.md «el día es el argentino, no el del servidor»). De día no se ve: el job «Gates y ensayos de SQL» dio rojo
 * a las 22:49 de Argentina con `test-ii-techo-y-condiciones-1596` y `test-subtotal-compra-1077`, que no habían
 * fallado nunca. Se arregla con `public._tablero_hoy()` o `(now() AT TIME ZONE 'America/Argentina/Tucuman')::date`.
 *
 * Este test falla ante un `CURRENT_DATE` / `now()::date` NUEVO en un ensayo. Los de la lista son los que ya estaban:
 * por archivo y con su cuenta, y sólo se achica (si arreglás uno, bajá o sacá su línea: el test falla si la lista
 * queda más ancha que lo que hay). Para probar un ensayo con el día corrido:
 *   GATE_DB_CONTENEDOR=<contenedor> node scripts/ci/ensayos-sql.mjs --tz Pacific/Kiritimati --solo <ensayo>
 * (con la sesión en UTC+14 es «mañana» respecto de Argentina casi todo el día).
 */
const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../scripts')

const OBJETIVO = 'su objetivo es probar el corte UTC / Argentina'
const OMITIDO = 'no corre en CI (pide dos sesiones)'
const DATOS =
  'exceptuado por datos (ensayos-sql-excepciones.json): no se puede probar con el día corrido hasta que corra entero; al arreglarlo, pasar al día argentino'
const CORRIDO = 'pasa con la sesión en Pacific/Kiritimati (B13d, 18/11/2026): pasar al día argentino cuando se lo toque'

const PERMITIDOS: Record<string, [number, string]> = {
  'test-anular-compra-nc-1095.sql': [1, CORRIDO],
  'test-anular-salvedad-compra-editada.sql': [1, CORRIDO],
  'test-cancelar-sin-huella-1114.sql': [1, CORRIDO],
  'test-cargo-4.sql': [6, DATOS],
  'test-cargo-5.sql': [2, DATOS],
  'test-catalogo-precios-ola2-1603.sql': [2, CORRIDO],
  'test-compra-nc-rest-1113.sql': [1, CORRIDO],
  'test-concurrencia-pago-fifo.sql': [1, OMITIDO],
  'test-devolucion-bolsa-1085.sql': [1, CORRIDO],
  'test-dia-argentino-1277.sql': [2, OBJETIVO],
  'test-eliminar-cancelado-1125.sql': [1, CORRIDO],
  'test-fechas-utc-1298.sql': [6, OBJETIVO],
  'test-gastos-2.sql': [2, CORRIDO],
  'test-gates-1330.sql': [2, DATOS],
  'test-huella-edicion-1094-1097.sql': [1, CORRIDO],
  'test-lotes-trazabilidad-1054-1073.sql': [1, CORRIDO],
  'test-nota-credito-lotes-1079.sql': [1, CORRIDO],
  'test-rama-admin-sucursal-1244.sql': [3, CORRIDO],
  'test-reportes-y-fechas-1262.sql': [1, CORRIDO],
  'test-rubros-consolidar-y-precios-en-masa-1561.sql': [1, CORRIDO],
  'test-rutas-1313.sql': [2, DATOS],
  'test-salvedad-anulada-foto-1595.sql': [1, CORRIDO],
  'test-salvedad-anular-1140-1142.sql': [1, CORRIDO],
  'test-salvedad-anular-1161-1164.sql': [1, CORRIDO],
  'test-salvedad-huella-1126-1127.sql': [1, CORRIDO],
  'test-seg-menores-1056.sql': [2, CORRIDO],
  'test-stock-integridad-1254-1255-1256.sql': [1, DATOS],
  'test-suplantar-admin-1048.sql': [14, CORRIDO],
}

const DIA_DEL_SERVIDOR = /\bCURRENT_DATE\b|\bnow\(\)\s*::\s*date\b|\(\s*now\(\)\s*\)\s*::\s*date\b|\bCURRENT_TIMESTAMP\s*::\s*date\b/gi

const sinComentarios = (sql: string) => sql.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/--[^\n]*/g, ' ')

const ensayos = fs.readdirSync(RAIZ).filter((f) => /^test-.*\.sql$/.test(f))
const cuenta = (f: string) =>
  (sinComentarios(fs.readFileSync(path.join(RAIZ, f), 'utf8').replace(/\r\n/g, '\n')).match(DIA_DEL_SERVIDOR) ?? []).length

describe('los ensayos de SQL usan el día argentino', () => {
  it('hay ensayos que mirar', () => {
    expect(ensayos.length).toBeGreaterThan(100)
  })

  it('ningún ensayo nombra el día del servidor fuera de la lista, y la lista no queda más ancha que lo que hay', () => {
    const sobran: string[] = []
    const nuevos: string[] = []
    for (const f of ensayos) {
      const n = cuenta(f)
      const permitido = PERMITIDOS[f]?.[0] ?? 0
      if (n > permitido) nuevos.push(`${f}: ${n} (permitidos ${permitido})`)
      if (n < permitido) sobran.push(`${f}: ${n} (la lista dice ${permitido})`)
    }
    expect(nuevos, 'CURRENT_DATE o now()::date en un ensayo: usá public._tablero_hoy()').toEqual([])
    expect(sobran, 'arreglaste uno: bajá o sacá su línea de PERMITIDOS').toEqual([])
  })

  it('cada línea de la lista es un ensayo que existe y dice por qué', () => {
    for (const [f, [n, motivo]] of Object.entries(PERMITIDOS)) {
      expect(ensayos, f).toContain(f)
      expect(n).toBeGreaterThan(0)
      expect(motivo.length).toBeGreaterThan(20)
    }
  })

  it('los dos que fallaron de noche ya no están en la lista', () => {
    expect(PERMITIDOS['test-ii-techo-y-condiciones-1596.sql']).toBeUndefined()
    expect(PERMITIDOS['test-subtotal-compra-1077.sql']).toBeUndefined()
  })
})
