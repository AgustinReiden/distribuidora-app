import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

/**
 * El trinquete de los lectores de número (B20, segunda lente y segunda pasada de #1644).
 *
 * Un campo de número tiene UN lector: el del componente (`NumberInput`, `CampoNumero`,
 * `InputMonto`) o el de `normalizarNumero.ts` / `calculations.ts` / `personal.ts` que el componente
 * usa para decidir el rojo. Si el formulario vuelve a leer el texto con otro (`replace(/\./g, '')`,
 * `replace(',', '.')`, `parseFloat`, `parseInt`, `Number(texto)`), el campo queda en rojo y se
 * guarda OTRO número: «185.000» (la tecla del punto) guardaba 185 km.
 *
 * Este test cuenta esos patrones en `src/components`, `src/hooks` y `src/utils` (menos los dos
 * archivos que SON los lectores: `normalizarNumero.ts` y `calculations.ts`) y falla si aparece uno
 * nuevo. Los que hoy quedan están en `lectoresNumero.permitidos.json`, cada uno con su motivo: la
 * lista sólo se achica (si un archivo tiene menos de los permitidos, también falla, para que se
 * baje el número).
 *
 * LO QUE UN TRINQUETE DE TEXTO NO VE (N13 de la segunda pasada):
 * - Un lector del repo equivocado para el campo: `leerNumero` donde iba `leerEntero` (así se rompió
 *   el tope del combo, H2) o `parsePrecio` sobre un porcentaje. Son los lectores buenos, en el lugar
 *   malo; lo cubren los tests que tipean en cada formulario («1.000» en un entero no se guarda).
 * - Un `null` que el formulario toma por «vacío» (el límite de usos de la promo, H3).
 * - Un lector armado con otros nombres (`+texto`, `texto * 1`, `Math.round(texto)`, una regex
 *   propia) o escondido en una función de otro archivo que no esté en el alcance.
 * - Que el valor que se lee sea lo tipeado: los permitidos están porque leen ids, `<select>` o datos
 *   de la base; si mañana uno de ellos pasa a leer un campo, el número no cambia y no falla.
 */
const __dirname = path.dirname(fileURLToPath(import.meta.url))
const RAIZ = path.resolve(__dirname, '../..')
const ALCANCE = ['src/components', 'src/hooks', 'src/utils'].map(d => path.join(RAIZ, d))
/** Los lectores mismos: ahí es donde se escribe la regla. */
const LECTORES = new Set(['src/utils/normalizarNumero.ts', 'src/utils/calculations.ts'])
const PERMITIDOS: unknown = JSON.parse(fs.readFileSync(path.join(__dirname, 'lectoresNumero.permitidos.json'), 'utf-8'))

const PATRONES: Record<string, RegExp> = {
  'parseFloat(': /\bparseFloat\(/g,
  'parseInt(': /\bparseInt\(/g,
  'Number(e.target.value': /\bNumber\(\s*e\.target\.value/g,
  // Un texto en una variable: `Number(kmTxt)`, `Number(texto)`, `Number(valorStr)`, `Number(value)`.
  'Number(texto)': /\bNumber\(\s*(?!e\.target\.value)[\w.]*(?:[Tt]xt|[Tt]exto|[Ss]tr|[Vv]alue)\s*\)/g,
  "replace(/\\./g": /\.replace\(\s*\/\\\.\/g/g,
  "replace(',', '.')": /\.replace\(\s*['"],['"]\s*,\s*['"]\.['"]\s*\)/g,
  'replace(/,/g': /\.replace\(\s*\/,\/g/g,
  "replaceAll('.'": /\.replaceAll\(\s*['"][.,]['"]/g,
  "split('.').join": /\.split\(\s*['"][.,]['"]\s*\)\s*\.join/g,
}

interface Permitido { archivo: string; patron: string; cantidad: number; motivo: string }

function archivosDeProduccion(dir: string): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(e => {
    const ruta = path.join(dir, e.name)
    if (e.isDirectory()) return e.name === '__tests__' ? [] : archivosDeProduccion(ruta)
    return /\.(ts|tsx)$/.test(e.name) && !/\.(test|spec|fixture)\./.test(e.name) ? [ruta] : []
  })
}

const relativo = (ruta: string): string => path.relative(RAIZ, ruta).replace(/\\/g, '/')

/** El código sin los comentarios de línea ni los de bloque (un comentario puede nombrar el patrón). */
function sinComentarios(texto: string): string {
  return texto
    .split('\n')
    .filter(l => !/^\s*(\/\/|\*|\/\*)/.test(l))
    .map(l => l.replace(/\s\/\/.*$/, ''))
    .join('\n')
}

function contarEn(codigo: string): Map<string, number> {
  const cuentas = new Map<string, number>()
  for (const [nombre, re] of Object.entries(PATRONES)) {
    const n = codigo.match(re)?.length ?? 0
    if (n > 0) cuentas.set(nombre, n)
  }
  return cuentas
}

function contar(): Map<string, number> {
  const cuentas = new Map<string, number>()
  for (const ruta of ALCANCE.flatMap(archivosDeProduccion)) {
    const archivo = relativo(ruta)
    if (LECTORES.has(archivo)) continue
    for (const [nombre, n] of contarEn(sinComentarios(fs.readFileSync(ruta, 'utf-8')))) cuentas.set(`${archivo} ${nombre}`, n)
  }
  return cuentas
}

describe('lectores de número tipeado: uno solo por campo (B20)', () => {
  const cuentas = contar()
  const permitidos = new Map((PERMITIDOS as Permitido[]).map(p => [`${p.archivo} ${p.patron}`, p]))

  it('encuentra el código a revisar', () => {
    expect(ALCANCE.flatMap(archivosDeProduccion).length).toBeGreaterThan(300)
  })

  it('ningún archivo lee lo tipeado con un lector propio que no esté en la lista', () => {
    const nuevos = [...cuentas].filter(([clave, n]) => n > (permitidos.get(clave)?.cantidad ?? 0))
      .map(([clave, n]) => `${clave}: ${n} (permitidos ${permitidos.get(clave)?.cantidad ?? 0})`)
    expect(nuevos, 'Leé el número con el lector del componente (NumberInput, CampoNumero, InputMonto) o con leerNumero / leerEntero / leerDecimalSinMiles / parsePrecio / parseMonto, el mismo que decide el rojo').toEqual([])
  })

  it('la lista de permitidos sólo se achica', () => {
    const sobrantes = [...permitidos].filter(([clave, p]) => (cuentas.get(clave) ?? 0) < p.cantidad)
      .map(([clave, p]) => `${clave}: hay ${cuentas.get(clave) ?? 0}, la lista dice ${p.cantidad}`)
    expect(sobrantes, 'Bajá la cantidad (o sacá la entrada) en lectoresNumero.permitidos.json').toEqual([])
  })

  // Las formas de leer que el trinquete ve. El tope del combo (H2, `leerNumero` en vez de
  // `leerEntero`) y el límite de la promo (H3, el `null` de un entero) NO están acá: no son un
  // patrón de texto (ver arriba).
  it.each([
    ['parseFloat(', 'parseFloat(precioTxt)'],
    ['parseInt(', 'const l = parseInt(limiteUsos)'],
    ['Number(e.target.value', 'setX(Number(e.target.value))'],
    ['Number(texto)', 'const km = Number(kmTxt)'],
    ["replace(/\\./g", "texto.replace(/\\./g, '')"],
    ["replace(',', '.')", "texto.replace(',', '.')"],
    ['replace(/,/g', "texto.replace(/,/g, '.')"],
    ["replaceAll('.'", "texto.replaceAll('.', '')"],
    ["split('.').join", "texto.split('.').join('')"],
  ])('el patrón %s atrapa %s', (nombre, codigo) => {
    expect(contarEn(codigo).get(nombre)).toBe(1)
  })

  it('cada permitido dice por qué', () => {
    for (const p of PERMITIDOS as Permitido[]) expect(p.motivo.length).toBeGreaterThan(10)
  })
})
