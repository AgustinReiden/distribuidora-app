/**
 * El "cerebro" del escáner de facturas (Entrega B): para cada línea escaneada,
 * a qué producto del catálogo corresponde y con cuánta seguridad.
 *
 * Lógica pura, sin supabase: la consume el modal de compra hoy y la pantalla de
 * revisión de la Entrega C mañana. Los datos que necesita los trae
 * `candidatos_escaneo` (mig 292): las equivalencias aprendidas del proveedor y
 * lo que ya se le compró, con el último costo.
 *
 * Cascada, de lo más seguro a lo menos:
 *   1. Equivalencia aprendida por código del proveedor      → vinculado, 1
 *   2. Equivalencia aprendida por descripción normalizada   → vinculado, 0.98
 *   3. `productos.codigo` exacto, ÚNICO en la sucursal      → vinculado, 0.9
 *      (repetido → sugerido; o si la descripción no comparte ni una palabra
 *      con el nombre, también sugerido: un código "100" del proveedor que
 *      coincide de casualidad con el nuestro no se vincula solo)
 *   4. Ranking difuso sobre todo el catálogo activo → como mucho `sugerido`.
 *      Lo difuso NUNCA vincula solo: lo confirma una persona.
 *
 * Nunca inventa: todo `productoId` que devuelve es un id del catálogo recibido.
 */

// =============================================================================
// Normalización (espejo de la SQL de la mig 292)
// =============================================================================

const ACENTOS_DESDE = 'ÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇáàäâãéèëêíìïîóòöôõúùüûñç'
const ACENTOS_HASTA = 'AAAAAEEEEIIIIOOOOOUUUUNCaaaaaeeeeiiiiooooouuuunc'
const MAPA_ACENTOS: Record<string, string> = Object.fromEntries(
  [...ACENTOS_DESDE].map((c, i) => [c, ACENTOS_HASTA[i]]),
)

/**
 * La llave de descripción de `producto_equivalencias_proveedor`. ESPEJO EXACTO
 * de `public.normalizar_descripcion_proveedor` (mig 292): si se cambia una, se
 * cambia la otra, o el matcher busca una descripción que la RPC guardó escrita
 * distinto y la equivalencia no aparece nunca, sin que falle nada.
 *
 *   1. '#' → espacio  2. acentos (lista explícita)  3. minúsculas
 *   4. coma/punto entre dígitos → punto decimal  5. lo que no sea [a-z0-9] →
 *   espacio  6. trim.  Devuelve '' (la SQL, NULL) si no queda nada.
 */
export function normalizarDescripcion(texto: string | null | undefined): string {
  return [...(texto ?? '').replace(/#/g, ' ')]
    .map(c => MAPA_ACENTOS[c] ?? c)
    .join('')
    .toLowerCase()
    .replace(/([0-9])[.,]([0-9])/g, '$1#$2')
    .replace(/[^a-z0-9#]+/g, ' ')
    .replace(/#/g, '.')
    .trim()
}

/** Código del proveedor: sin espacios y en mayúsculas (mismo criterio que la RPC). */
export function normalizarCodigoProveedor(codigo: string | number | null | undefined): string {
  return String(codigo ?? '').replace(/\s+/g, '').toUpperCase()
}

// =============================================================================
// Tipos
// =============================================================================

/** Una línea de la factura escaneada (lo que devuelve la extracción). */
export interface LineaEscaneada {
  codigo: string | null;
  descripcion: string;
  cantidad?: number | null;
  /** Precio unitario neto impreso. Se compara contra el último costo del par. */
  precioUnitarioNeto?: number | null;
}

/** Lo mínimo de un producto del catálogo que mira el matcher. */
export interface ProductoMatchable {
  id: string | number;
  nombre: string;
  codigo?: string | null;
  activo?: boolean | null;
  proveedor_id?: string | number | null;
}

/** Una equivalencia aprendida (fila de producto_equivalencias_proveedor). */
export interface EquivalenciaProveedor {
  productoId: string;
  codigoProveedor: string | null;
  descripcionNormalizada: string;
  unidadesPorBulto: number | null;
}

/** Un producto que ya se le compró a este proveedor, con el último costo unitario. */
export interface CompradoAntes {
  productoId: string;
  ultimoCosto: number | null;
}

export type EstadoMatch = 'vinculado' | 'sugerido' | 'sin_match'

export interface AlternativaMatch {
  productoId: string;
  /** Puntaje 0-1 del ranking difuso. */
  puntaje: number;
}

export interface ResultadoMatchLinea {
  estado: EstadoMatch;
  /** Siempre un id del catálogo. Ausente en `sin_match`. */
  productoId?: string;
  confianza: number;
  /** Por qué, en castellano, para mostrar. */
  motivo: string;
  /** Hasta 3 candidatos más (sin el elegido). */
  alternativas: AlternativaMatch[];
  /** Conversión de la equivalencia: unidades nuestras por unidad facturada. */
  unidadesPorBulto?: number;
  /** Otras líneas (índices) que resolvieron al mismo producto. C las fusiona. */
  duplicadoCon?: number[];
}

export interface EntradaMatchEscaneo {
  lineas: LineaEscaneada[];
  /** Sin proveedor no hay equivalencias ni historial: sólo catálogo. */
  proveedorId: string | number | null;
  catalogo: ProductoMatchable[];
  equivalencias?: EquivalenciaProveedor[];
  comprados?: CompradoAntes[];
}

// =============================================================================
// Rasgos de una descripción: palabras, tamaños y packs
// =============================================================================

interface Medida { dim: 'vol' | 'peso'; valor: number }

export interface RasgosDescripcion {
  tokens: string[];
  medidas: Medida[];
  /** Números sin unidad ("COCA COLA 1500", "MANAOS COLA 2.25", el 600 de "600X12"). */
  sueltos: number[];
  /** Unidades del pack: "x 12", "X6", el 12 de "600X12". */
  packs: number[];
}

const UNIDADES: Record<string, { dim: 'vol' | 'peso'; factor: number }> = {
  cc: { dim: 'vol', factor: 1 }, ml: { dim: 'vol', factor: 1 }, cm3: { dim: 'vol', factor: 1 },
  l: { dim: 'vol', factor: 1000 }, lt: { dim: 'vol', factor: 1000 }, lts: { dim: 'vol', factor: 1000 },
  litro: { dim: 'vol', factor: 1000 }, litros: { dim: 'vol', factor: 1000 },
  g: { dim: 'peso', factor: 1 }, gr: { dim: 'peso', factor: 1 }, grs: { dim: 'peso', factor: 1 },
  gramos: { dim: 'peso', factor: 1 },
  kg: { dim: 'peso', factor: 1000 }, kgs: { dim: 'peso', factor: 1000 }, kilo: { dim: 'peso', factor: 1000 },
  kilos: { dim: 'peso', factor: 1000 },
}
const RE_MEDIDA = new RegExp(`(\\d+(?:\\.\\d+)?)\\s*(${Object.keys(UNIDADES).sort((a, b) => b.length - a.length).join('|')})\\b`, 'g')
const RE_NUM_X_NUM = /(\d+(?:\.\d+)?)\s*x\s*(\d+)\b/g
const RE_PACK = /(?:^|\s)x\s*(\d+)\b/g

/** Palabras que no distinguen un producto de otro. */
const VACIAS = new Set(['x', 'de', 'del', 'la', 'el', 'los', 'las', 'en', 'y', 'u', 'un', 'unid', 'unidad', 'unidades', 'por', 'para'])

/**
 * Palabras que, si están de un lado y no del otro, cambian el producto:
 * una Coca Zero no es una Coca, un agua con gas no es una sin gas.
 */
const DISCRIMINANTES = new Set(['zero', 'light', 'lite', 'diet', 'sin', 'con', 'descafeinado'])

/** Abreviaturas de factura, antes de normalizar ("S/G" → "sin gas"). */
function expandirAbreviaturas(texto: string): string {
  return ` ${texto.toLowerCase()} `
    .replace(/(^|[^a-z])s\s*\/\s*g(?![a-z])/g, '$1 sin gas ')
    .replace(/(^|[^a-z])c\s*\/\s*g(?![a-z])/g, '$1 con gas ')
    .replace(/(^|[^a-z])s\s*\//g, '$1 sin ')
    .replace(/(^|[^a-z])c\s*\//g, '$1 con ')
    .replace(/(^|[^a-z])p\s*\//g, '$1 para ')
}

export function rasgosDescripcion(texto: string | null | undefined): RasgosDescripcion {
  let s = ` ${normalizarDescripcion(expandirAbreviaturas(texto ?? ''))} `
  const medidas: Medida[] = []
  const sueltos: number[] = []
  const packs: number[] = []

  s = s.replace(RE_MEDIDA, (_, num: string, unidad: string) => {
    const u = UNIDADES[unidad]
    medidas.push({ dim: u.dim, valor: Number(num) * u.factor })
    return ' '
  })
  s = s.replace(RE_NUM_X_NUM, (_, tam: string, pack: string) => {
    sueltos.push(Number(tam))
    packs.push(Number(pack))
    return ' '
  })
  s = s.replace(RE_PACK, (_, pack: string) => {
    packs.push(Number(pack))
    return ' '
  })

  const tokens: string[] = []
  for (const t of s.split(' ')) {
    if (!t) continue
    if (/^\d+(\.\d+)?$/.test(t)) { sueltos.push(Number(t)); continue }
    if (VACIAS.has(t)) continue
    // "x6" pegado (el RE_PACK pide espacio o principio antes de la x).
    const pegado = /^x(\d+)$/.exec(t)
    if (pegado) { packs.push(Number(pegado[1])); continue }
    tokens.push(t)
  }
  return { tokens, medidas, sueltos, packs }
}

// =============================================================================
// Similitud
// =============================================================================

function casiIgual(a: number, b: number): boolean {
  return Math.abs(a - b) <= Math.max(a, b) * 0.02
}

/** Un número suelto es compatible con una medida si es la medida en ml/g o en l/kg. */
function sueltoCompatible(n: number, m: Medida): boolean {
  return casiIgual(n, m.valor) || casiIgual(n * 1000, m.valor)
}

type Veredicto = 'igual' | 'distinto' | 'desconocido'

/** ¿Los tamaños de las dos descripciones dicen lo mismo? */
export function compararTamano(a: RasgosDescripcion, b: RasgosDescripcion): { veredicto: Veredicto; fuerte: boolean } {
  for (const dim of ['vol', 'peso'] as const) {
    const ma = a.medidas.filter(m => m.dim === dim)
    const mb = b.medidas.filter(m => m.dim === dim)
    if (ma.length && mb.length) {
      const igual = ma.some(x => mb.some(y => casiIgual(x.valor, y.valor)))
      return { veredicto: igual ? 'igual' : 'distinto', fuerte: true }
    }
  }
  const medidasA = a.medidas, medidasB = b.medidas
  if (medidasA.length && b.sueltos.length) {
    const ok = b.sueltos.some(n => medidasA.some(m => sueltoCompatible(n, m)))
    return { veredicto: ok ? 'igual' : 'distinto', fuerte: true }
  }
  if (medidasB.length && a.sueltos.length) {
    const ok = a.sueltos.some(n => medidasB.some(m => sueltoCompatible(n, m)))
    return { veredicto: ok ? 'igual' : 'distinto', fuerte: true }
  }
  if (a.sueltos.length && b.sueltos.length) {
    const ok = a.sueltos.some(x => b.sueltos.some(y => casiIgual(x, y) || casiIgual(x * 1000, y) || casiIgual(x, y * 1000)))
    // Dos números sueltos que no coinciden pueden no ser tamaños ("#3", "4 quesos"):
    // pesa, pero menos que una medida con unidad.
    return { veredicto: ok ? 'igual' : 'distinto', fuerte: false }
  }
  return { veredicto: 'desconocido', fuerte: false }
}

function comparaPack(a: RasgosDescripcion, b: RasgosDescripcion): Veredicto {
  if (!a.packs.length || !b.packs.length) return 'desconocido'
  return a.packs.some(x => b.packs.includes(x)) ? 'igual' : 'distinto'
}

function levenshteinHasta1(a: string, b: string): boolean {
  if (Math.abs(a.length - b.length) > 1) return false
  let i = 0, j = 0, ediciones = 0
  while (i < a.length && j < b.length) {
    if (a[i] === b[j]) { i++; j++; continue }
    if (++ediciones > 1) return false
    if (a.length > b.length) i++
    else if (b.length > a.length) j++
    else { i++; j++ }
  }
  return ediciones + (a.length - i) + (b.length - j) <= 1
}

/** 1 igual · 0.9 una es prefijo de la otra ("villam" / "villamanaos") · 0.8 un error de tipeo. */
function similitudToken(a: string, b: string): number {
  if (a === b) return 1
  // "con" no es el principio de "condimento" ni "sin" un typo de "sal".
  if (DISCRIMINANTES.has(a) || DISCRIMINANTES.has(b)) return 0
  const [corta, larga] = a.length <= b.length ? [a, b] : [b, a]
  if (corta.length >= 3 && larga.startsWith(corta)) return 0.9
  if (corta.length >= 4 && levenshteinHasta1(a, b)) return 0.8
  return 0
}

type Pesos = (token: string) => number

/**
 * Dice ponderado por rareza: cada palabra de la línea se empareja con la mejor
 * libre del nombre. Las palabras raras del catálogo (la marca, "zero") pesan
 * más que las comunes ("agua", "manaos").
 */
function similitudTokens(scan: string[], prod: string[], peso: Pesos): number {
  if (!scan.length || !prod.length) return 0
  const usados = new Set<number>()
  let comun = 0
  for (const t of scan) {
    let mejor = 0, mejorIdx = -1
    prod.forEach((p, idx) => {
      if (usados.has(idx)) return
      const s = similitudToken(t, p)
      if (s > mejor) { mejor = s; mejorIdx = idx }
    })
    if (mejorIdx >= 0) {
      usados.add(mejorIdx)
      comun += mejor * peso(prod[mejorIdx])
    }
  }
  const total = scan.reduce((acc, t) => acc + peso(t), 0) + prod.reduce((acc, t) => acc + peso(t), 0)
  return total > 0 ? (2 * comun) / total : 0
}

function discriminantesChocan(scan: string[], prod: string[]): boolean {
  const a = new Set(scan.filter(t => DISCRIMINANTES.has(t)))
  const b = new Set(prod.filter(t => DISCRIMINANTES.has(t)))
  for (const t of a) if (!b.has(t)) return true
  for (const t of b) if (!a.has(t)) return true
  return false
}

/** Pesos por rareza en el catálogo (idf acotado). */
function pesosDelCatalogo(rasgos: RasgosDescripcion[]): Pesos {
  const df = new Map<string, number>()
  for (const r of rasgos) for (const t of new Set(r.tokens)) df.set(t, (df.get(t) ?? 0) + 1)
  const n = Math.max(rasgos.length, 1)
  return (token: string) => {
    const d = df.get(token)
    // Palabra que el catálogo no tiene: peso medio. No sirve para elegir, pero
    // tampoco puede regalar puntaje.
    if (!d) return 1
    return Math.min(3, Math.max(0.5, Math.log(1 + n / d)))
  }
}

// =============================================================================
// Puntaje de un candidato
// =============================================================================

export const UMBRAL_SUGERIDO = 0.72
export const MARGEN_SUGERIDO = 0.08
const CONFIANZA_MAX_DIFUSA = 0.89

interface Contexto {
  pesos: Pesos;
  costoPorProducto: Map<string, number | null>;
  proveedorId: string | null;
}

interface Candidato { producto: ProductoMatchable; rasgos: RasgosDescripcion }

function puntaje(linea: LineaEscaneada, rl: RasgosDescripcion, c: Candidato, ctx: Contexto): { puntaje: number; texto: number } {
  const texto = similitudTokens(rl.tokens, c.rasgos.tokens, ctx.pesos)
  let p = texto

  const tam = compararTamano(rl, c.rasgos)
  if (tam.veredicto === 'distinto') p *= tam.fuerte ? 0.35 : 0.7
  else if (tam.veredicto === 'igual') p += 0.05

  const pack = comparaPack(rl, c.rasgos)
  if (pack === 'distinto') p *= 0.4
  else if (pack === 'igual') p += 0.03

  if (discriminantesChocan(rl.tokens, c.rasgos.tokens)) p *= 0.5

  const id = String(c.producto.id)
  const precio = linea.precioUnitarioNeto
  const costo = ctx.costoPorProducto.get(id)
  if (precio && precio > 0 && costo && costo > 0) {
    const r = precio / costo
    if (r >= 0.75 && r <= 1.25) p += 0.08
    else if (r > 2 || r < 0.5) p *= 0.6
  }

  if (ctx.costoPorProducto.has(id)) p += 0.05
  if (ctx.proveedorId && c.producto.proveedor_id != null && String(c.producto.proveedor_id) === ctx.proveedorId) p += 0.03

  // Sin acotar: el orden y el margen se miden sobre el bruto, para que dos
  // candidatos que pasan de 1 no queden empatados por el tope. Al mostrarlo
  // se acota a [0, 1].
  return { puntaje: Math.max(0, p), texto }
}

function redondear(n: number): number {
  return Math.round(n * 1000) / 1000
}

// =============================================================================
// El matcher
// =============================================================================

export function matchEscaneo(entrada: EntradaMatchEscaneo): ResultadoMatchLinea[] {
  const catalogo = entrada.catalogo.filter(p => p.activo !== false)
  const porId = new Map(catalogo.map(p => [String(p.id), p]))
  const candidatos: Candidato[] = catalogo.map(p => ({ producto: p, rasgos: rasgosDescripcion(p.nombre) }))
  const proveedorId = entrada.proveedorId == null || entrada.proveedorId === '' ? null : String(entrada.proveedorId)

  // Sin proveedor no hay de quién aprender: ni equivalencias ni historial.
  const equivalencias = proveedorId ? (entrada.equivalencias ?? []) : []
  const comprados = proveedorId ? (entrada.comprados ?? []) : []

  const ctx: Contexto = {
    pesos: pesosDelCatalogo(candidatos.map(c => c.rasgos)),
    costoPorProducto: new Map(comprados.map(c => [String(c.productoId), c.ultimoCosto])),
    proveedorId,
  }

  // Sólo las equivalencias cuyo producto sigue en el catálogo activo: un
  // producto dado de baja no se ofrece aunque se haya aprendido.
  const eqPorCodigo = new Map<string, EquivalenciaProveedor>()
  const eqPorDescripcion = new Map<string, EquivalenciaProveedor>()
  for (const e of equivalencias) {
    if (!porId.has(String(e.productoId))) continue
    if (e.codigoProveedor) eqPorCodigo.set(normalizarCodigoProveedor(e.codigoProveedor), e)
    eqPorDescripcion.set(e.descripcionNormalizada, e)
  }

  const productosPorCodigo = new Map<string, ProductoMatchable[]>()
  for (const p of catalogo) {
    const cod = normalizarCodigoProveedor(p.codigo)
    if (!cod) continue
    productosPorCodigo.set(cod, [...(productosPorCodigo.get(cod) ?? []), p])
  }

  const resultados = entrada.lineas.map((linea): ResultadoMatchLinea => {
    const rl = rasgosDescripcion(linea.descripcion)
    const ranking = candidatos
      .map(c => ({ c, ...puntaje(linea, rl, c, ctx) }))
      .sort((a, b) => b.puntaje - a.puntaje)
    const alternativasSin = (excluir?: string): AlternativaMatch[] =>
      ranking
        .filter(r => String(r.c.producto.id) !== excluir && r.puntaje >= 0.25)
        .slice(0, 3)
        .map(r => ({ productoId: String(r.c.producto.id), puntaje: redondear(Math.min(1, r.puntaje)) }))
    const conConversion = (e: EquivalenciaProveedor) =>
      e.unidadesPorBulto && e.unidadesPorBulto > 0 ? { unidadesPorBulto: e.unidadesPorBulto } : {}

    // 1 · equivalencia por código del proveedor
    const cod = normalizarCodigoProveedor(linea.codigo)
    if (cod) {
      const e = eqPorCodigo.get(cod)
      if (e) {
        return {
          estado: 'vinculado', productoId: String(e.productoId), confianza: 1,
          motivo: 'Ya vinculaste este código de este proveedor',
          alternativas: [], ...conConversion(e),
        }
      }
    }

    // 2 · equivalencia por descripción
    const desc = normalizarDescripcion(linea.descripcion)
    if (desc) {
      const e = eqPorDescripcion.get(desc)
      if (e) {
        return {
          estado: 'vinculado', productoId: String(e.productoId), confianza: 0.98,
          motivo: 'Ya vinculaste esta descripción de este proveedor',
          alternativas: [], ...conConversion(e),
        }
      }
    }

    // 3 · nuestro código
    if (cod) {
      const mismos = productosPorCodigo.get(cod) ?? []
      if (mismos.length === 1) {
        const id = String(mismos[0].id)
        const fila = ranking.find(r => String(r.c.producto.id) === id)
        if (fila && fila.texto > 0) {
          return { estado: 'vinculado', productoId: id, confianza: 0.9, motivo: 'El código coincide con el del producto', alternativas: [] }
        }
        return {
          estado: 'sugerido', productoId: id, confianza: 0.6,
          motivo: 'El código coincide, pero la descripción no se parece al nombre',
          alternativas: alternativasSin(id),
        }
      }
      if (mismos.length > 1) {
        const ids = new Set(mismos.map(p => String(p.id)))
        const entreEllos = ranking.filter(r => ids.has(String(r.c.producto.id)))
        const elegido = String(entreEllos[0].c.producto.id)
        return {
          estado: 'sugerido', productoId: elegido, confianza: 0.6,
          motivo: `El código está repetido en ${mismos.length} productos: elegí el que corresponde`,
          alternativas: entreEllos.slice(1, 4).map(r => ({ productoId: String(r.c.producto.id), puntaje: redondear(Math.min(1, r.puntaje)) })),
        }
      }
    }

    // 4 · ranking difuso: como mucho sugerido
    const [primero, segundo] = ranking
    if (primero && primero.puntaje >= UMBRAL_SUGERIDO && primero.puntaje - (segundo?.puntaje ?? 0) >= MARGEN_SUGERIDO) {
      const id = String(primero.c.producto.id)
      return {
        estado: 'sugerido', productoId: id,
        confianza: redondear(Math.min(CONFIANZA_MAX_DIFUSA, primero.puntaje)),
        motivo: ctx.costoPorProducto.has(id) ? 'Parecido a un producto que ya le compraste' : 'Parecido por nombre y tamaño',
        alternativas: alternativasSin(id),
      }
    }
    return {
      estado: 'sin_match', confianza: redondear(Math.min(1, primero?.puntaje ?? 0)),
      motivo: primero && primero.puntaje >= 0.25 ? 'Hay parecidos, pero ninguno con suficiente seguridad' : 'No se encontró nada parecido',
      alternativas: alternativasSin(),
    }
  })

  // 6 · dos líneas al mismo producto: se marca, no se fusiona acá.
  const lineasPorProducto = new Map<string, number[]>()
  resultados.forEach((r, i) => {
    if (!r.productoId) return
    lineasPorProducto.set(r.productoId, [...(lineasPorProducto.get(r.productoId) ?? []), i])
  })
  for (const indices of lineasPorProducto.values()) {
    if (indices.length < 2) continue
    for (const i of indices) resultados[i].duplicadoCon = indices.filter(j => j !== i)
  }
  return resultados
}

// =============================================================================
// Proveedor
// =============================================================================

export interface ProveedorMatchable {
  id: string | number;
  nombre: string;
  cuit?: string | null;
  activo?: boolean | null;
}

export interface ResultadoMatchProveedor {
  estado: EstadoMatch;
  proveedorId?: string;
  confianza: number;
  motivo: string;
  alternativas: Array<{ proveedorId: string; puntaje: number }>;
}

const SOCIETARIAS = new Set(['sa', 'srl', 'sas', 'sh', 'sociedad', 'anonima', 'cia', 'hnos', 'hermanos', 'y', 'de', 'la', 'el', 's', 'a', 'r', 'l'])

function tokensProveedor(nombre: string): string[] {
  return normalizarDescripcion(nombre).split(' ').filter(t => t && !SOCIETARIAS.has(t))
}

function soloDigitos(cuit: string | null | undefined): string {
  return (cuit ?? '').replace(/\D/g, '')
}

/** CUIT primero (vinculado); si no, parecido de nombre → como mucho sugerido. */
export function matchProveedor(
  scan: { nombre: string | null; cuit: string | null },
  proveedores: ProveedorMatchable[],
): ResultadoMatchProveedor {
  const activos = proveedores.filter(p => p.activo !== false)
  const cuit = soloDigitos(scan.cuit)
  if (cuit) {
    const porCuit = activos.find(p => soloDigitos(p.cuit) === cuit)
    if (porCuit) {
      return { estado: 'vinculado', proveedorId: String(porCuit.id), confianza: 1, motivo: 'El CUIT coincide', alternativas: [] }
    }
  }
  const tokens = tokensProveedor(scan.nombre ?? '')
  if (!tokens.length) return { estado: 'sin_match', confianza: 0, motivo: 'La factura no trae nombre ni CUIT conocido', alternativas: [] }

  const ranking = activos
    .map(p => ({ p, puntaje: similitudTokens(tokens, tokensProveedor(p.nombre), () => 1) }))
    .sort((a, b) => b.puntaje - a.puntaje)
  const alternativas = (excluir?: string) => ranking
    .filter(r => String(r.p.id) !== excluir && r.puntaje >= 0.3)
    .slice(0, 3)
    .map(r => ({ proveedorId: String(r.p.id), puntaje: redondear(r.puntaje) }))
  const [primero, segundo] = ranking
  if (primero && primero.puntaje >= 0.8 && primero.puntaje - (segundo?.puntaje ?? 0) >= 0.1) {
    const id = String(primero.p.id)
    return {
      estado: 'sugerido', proveedorId: id, confianza: redondear(Math.min(CONFIANZA_MAX_DIFUSA, primero.puntaje)),
      motivo: 'El nombre se parece', alternativas: alternativas(id),
    }
  }
  return { estado: 'sin_match', confianza: redondear(primero?.puntaje ?? 0), motivo: 'Ningún proveedor coincide con seguridad', alternativas: alternativas() }
}

// =============================================================================
// Lo que se aprende al guardar
// =============================================================================

/** El texto de la factura del que salió una línea de la compra. */
export interface OrigenEscaneo {
  codigo: string | null;
  descripcion: string;
}

/** Una fila para `registrar_equivalencias_proveedor`. */
export interface EquivalenciaARegistrar {
  producto_id: string;
  codigo_proveedor: string | null;
  descripcion: string;
}

/**
 * Las equivalencias que confirma una compra guardada: cada línea escaneada
 * (vinculada sola, vinculada a mano o creada) contra el producto con el que
 * quedó. Una por llave: si la misma descripción aparece dos veces, cuenta una.
 *
 * NO manda `unidades_por_bulto`: la pantalla de hoy no la pregunta, y sin la
 * clave la RPC conserva la que ya estaba (ver mig 292).
 */
export function equivalenciasParaRegistrar(
  items: Array<{ productoId: string | number; origenesEscaneo?: OrigenEscaneo[] }>,
): EquivalenciaARegistrar[] {
  const vistas = new Set<string>()
  const salida: EquivalenciaARegistrar[] = []
  for (const item of items) {
    for (const o of item.origenesEscaneo ?? []) {
      const desc = normalizarDescripcion(o.descripcion)
      if (!desc) continue
      const clave = `${normalizarCodigoProveedor(o.codigo)}|${desc}`
      if (vistas.has(clave)) continue
      vistas.add(clave)
      salida.push({
        producto_id: String(item.productoId),
        codigo_proveedor: normalizarCodigoProveedor(o.codigo) || null,
        descripcion: o.descripcion,
      })
    }
  }
  return salida
}
