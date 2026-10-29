/**
 * Qué archivos mira el gate de embeds y qué omisiones se aceptan a sabiendas.
 * Lo usan `scripts/check-embeds.mjs` y el test del repo
 * (`src/test/embedsRepo.test.ts`), que tienen que ver exactamente lo mismo.
 */
import { readdirSync, readFileSync } from 'node:fs'
import { join, relative, sep } from 'node:path'

const IGNORAR_DIR = new Set(['node_modules', '__tests__', 'tests', 'test', '.git', 'dist'])

function archivos(dir) {
  const salida = []
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (e.isDirectory()) {
      if (!IGNORAR_DIR.has(e.name)) salida.push(...archivos(join(dir, e.name)))
    } else if (/\.(ts|tsx)$/.test(e.name) && !/\.(test|spec)\./.test(e.name) && !e.name.endsWith('.d.ts')) {
      salida.push(join(dir, e.name))
    }
  }
  return salida
}

/** `[ruta posix relativa a la raíz, contenido][]` de `src/` y `supabase/functions/`. */
export function leerFuentes(raiz) {
  return [join(raiz, 'src'), join(raiz, 'supabase', 'functions')]
    .flatMap(archivos)
    .map((f) => [relative(raiz, f).split(sep).join('/'), readFileSync(f, 'utf8')])
}

/**
 * Omisiones legítimas: lo que el extractor no puede leer y alguien revisó a
 * mano. La clave es archivo + firma de la llamada (el texto de la llamada sin
 * espacios de más), no el número de línea, para que no se rompa al editar el
 * archivo y sí se rompa al cambiar la consulta.
 *
 * Una entrada que ya no matchea nada hace fallar el gate: si la consulta
 * cambió, hay que volver a mirarla.
 */
export const LISTA_BLANCA = [
  {
    archivo: 'src/hooks/supabase/useBackup.ts',
    firma: 'from(tabla)',
    motivo:
      'bajarTodoVerificado cuenta filas de la tabla que le pasan (clientes, productos, pedidos) con select("id", head): '
      + 'la tabla es un parámetro. No tiene embed, e `id` es legible en las tres (las tres consultas de datos se prueban aparte).',
  },
]

/** Separa los omitidos que cubre la lista blanca y las entradas que ya no cubren nada. */
export function aplicarListaBlanca(omitidos, lista = LISTA_BLANCA) {
  const usadas = new Set()
  const vigentes = []
  for (const o of omitidos) {
    const e = lista.find((x) => x.archivo === o.archivo && x.firma === o.firma)
    if (e) usadas.add(e)
    else vigentes.push(o)
  }
  return { vigentes, sinUso: lista.filter((e) => !usadas.has(e)) }
}
