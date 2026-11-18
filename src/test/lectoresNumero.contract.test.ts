import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

/**
 * El trinquete de los lectores de número (B20, segunda lente de #1644).
 *
 * Un campo de número tiene UN lector: el del componente (`NumberInput`, `CampoNumero`,
 * `InputMonto`) o el de `normalizarNumero.ts` / `calculations.ts` / `personal.ts` que el componente
 * usa para decidir el rojo. Si el formulario vuelve a leer el texto con otro (`replace(/\./g, '')`,
 * `replace(',', '.')`, `parseFloat`, `parseInt`, `Number(e.target.value)`), el campo queda en rojo y
 * se guarda OTRO número: «185.000» (la tecla del punto) guardaba 185 km, el tope «1.000» de un combo
 * guardaba 1.
 *
 * Este test cuenta esos patrones en `src/components` y falla si aparece uno nuevo. Los que hoy quedan
 * están en `lectoresNumero.permitidos.json`, cada uno con su motivo: la lista sólo se achica (si un
 * archivo tiene menos de los permitidos, también falla, para que se baje el número).
 */
const __dirname = path.dirname(fileURLToPath(import.meta.url))
const COMPONENTES = path.resolve(__dirname, '../components')
const PERMITIDOS: unknown = JSON.parse(fs.readFileSync(path.join(__dirname, 'lectoresNumero.permitidos.json'), 'utf-8'))

const PATRONES: Record<string, RegExp> = {
  'parseFloat(': /\bparseFloat\(/g,
  'parseInt(': /\bparseInt\(/g,
  'Number(e.target.value': /\bNumber\(\s*e\.target\.value/g,
  "replace(/\\./g": /\.replace\(\s*\/\\\.\/g/g,
  "replace(',', '.')": /\.replace\(\s*['"],['"]\s*,\s*['"]\.['"]\s*\)/g,
}

interface Permitido { archivo: string; patron: string; cantidad: number; motivo: string }

function archivosDeProduccion(dir: string): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(e => {
    const ruta = path.join(dir, e.name)
    if (e.isDirectory()) return e.name === '__tests__' ? [] : archivosDeProduccion(ruta)
    return /\.(ts|tsx)$/.test(e.name) && !/\.(test|spec)\./.test(e.name) ? [ruta] : []
  })
}

/** El código sin los comentarios de línea ni los de bloque (un comentario puede nombrar el patrón). */
function sinComentarios(texto: string): string {
  return texto
    .split('\n')
    .filter(l => !/^\s*(\/\/|\*|\/\*)/.test(l))
    .map(l => l.replace(/\s\/\/.*$/, ''))
    .join('\n')
}

function contar(): Map<string, number> {
  const cuentas = new Map<string, number>()
  for (const ruta of archivosDeProduccion(COMPONENTES)) {
    const codigo = sinComentarios(fs.readFileSync(ruta, 'utf-8'))
    const archivo = path.relative(path.resolve(__dirname, '../..'), ruta).replace(/\\/g, '/')
    for (const [nombre, re] of Object.entries(PATRONES)) {
      const n = codigo.match(re)?.length ?? 0
      if (n > 0) cuentas.set(`${archivo} ${nombre}`, n)
    }
  }
  return cuentas
}

describe('lectores de número tipeado: uno solo por campo (B20)', () => {
  const cuentas = contar()
  const permitidos = new Map((PERMITIDOS as Permitido[]).map(p => [`${p.archivo} ${p.patron}`, p]))

  it('encuentra el código a revisar', () => {
    expect(archivosDeProduccion(COMPONENTES).length).toBeGreaterThan(100)
  })

  it('ningún componente lee lo tipeado con un lector propio que no esté en la lista', () => {
    const nuevos = [...cuentas].filter(([clave, n]) => n > (permitidos.get(clave)?.cantidad ?? 0))
      .map(([clave, n]) => `${clave}: ${n} (permitidos ${permitidos.get(clave)?.cantidad ?? 0})`)
    expect(nuevos, 'Leé el número con el lector del componente (NumberInput, CampoNumero, InputMonto) o con leerNumero / leerEntero / leerDecimalSinMiles / parsePrecio / parseMonto, el mismo que decide el rojo').toEqual([])
  })

  it('la lista de permitidos sólo se achica', () => {
    const sobrantes = [...permitidos].filter(([clave, p]) => (cuentas.get(clave) ?? 0) < p.cantidad)
      .map(([clave, p]) => `${clave}: hay ${cuentas.get(clave) ?? 0}, la lista dice ${p.cantidad}`)
    expect(sobrantes, 'Bajá la cantidad (o sacá la entrada) en lectoresNumero.permitidos.json').toEqual([])
  })

  it('los patrones atrapan los lectores que rompieron (km, tope, límite)', () => {
    const roto = "const km = Number(kmTxt.replace(/\\./g, '').replace(',', '.'))\nconst l = parseInt(limiteUsos)\nsetX(Number(e.target.value))\nparseFloat(v)"
    for (const [nombre, re] of Object.entries(PATRONES)) {
      expect(roto.match(re)?.length ?? 0, nombre).toBeGreaterThan(0)
    }
  })

  it('cada permitido dice por qué', () => {
    for (const p of PERMITIDOS as Permitido[]) expect(p.motivo.length).toBeGreaterThan(10)
  })
})
