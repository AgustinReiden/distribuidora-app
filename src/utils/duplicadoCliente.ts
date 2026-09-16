/**
 * Criterio de cliente duplicado. Se escribe UNA vez acá y lo consumen las dos
 * mitades del guard: el front (`createCliente`, `ClientesContainer`) y la RPC
 * `verificar_duplicado_cliente` de la migración, que lo duplica en SQL con un
 * bloque DO que fija los mismos casos. Si las dos se desincronizan, ese test
 * se pone rojo.
 *
 * ---------------------------------------------------------------------------
 * Por qué no alcanza con las coordenadas
 * ---------------------------------------------------------------------------
 * El detector anterior era por coordenadas EXACTAS: desde el commit 4f5a6ee
 * (2026-03-31) la tolerancia es 0.000002 grados, o sea ~0,2 m. Las coordenadas
 * de un alta salen de dos caminos que nunca dan el mismo punto —el autocomplete
 * de Google Places y el GPS del teléfono con reverse geocoding—, así que dos
 * altas de la MISMA puerta caen a metros de distancia y el guard no ve nada.
 * El caso testigo es el par 382/938 en prod: misma dirección formateada, a
 * 17,5 m.
 *
 * Subir la tolerancia a 10 o 22 m no es la respuesta: medido sobre los 587
 * clientes con coordenadas de la sucursal 1, hay 45 pares a menos de 5 m y 57 a
 * menos de 10, y entre 1,4 y 8,6 m hay comercios DISTINTOS de verdad (un kiosco
 * y una fiambrería a 1,4 m; una panadería y una rotisería a 2,2 m). Ahí no se
 * puede bloquear: se avisa.
 *
 * ---------------------------------------------------------------------------
 * Las tres reglas
 * ---------------------------------------------------------------------------
 * 1. DIRECCIÓN con altura → bloqueo duro. La clave normalizada del primer
 *    segmento de la dirección, aplicada sólo si tiene al menos un dígito. Sin
 *    exigir el dígito, los barrios sin numeración se bloquearían entre sí
 *    (170 clientes de la sucursal 2 comparten "b esperanza" y "b sagrado").
 *    Es la regla que ataja el 382/938.
 * 2. DISTANCIA real en metros (haversine, no un box en grados, que se deforma
 *    con la latitud). Menos de 1 m es "el mismo punto" → bloqueo duro. Entre 1
 *    y 30 m → aviso con confirmación explícita. Más de 30 → nada.
 * 3. NOMBRE por tokens sin acentos, contra razón social Y nombre de fantasía.
 *    Igualdad exacta normalizada → bloqueo. Un conjunto de tokens contenido en
 *    el otro ("ricardo" dentro de "lopez ricardo") → aviso, nunca bloqueo:
 *    "Kiosco" está dentro de "Kiosco Juan" y son dos comercios.
 *
 * Los bloqueos tienen prioridad sobre los avisos, y entre sí van en el orden de
 * arriba.
 */

import { haversineMeters } from './geo'

/** Menos de esto es "el mismo punto": bloqueo duro. */
export const DUPLICADO_BLOQUEO_METROS = 1

/** Hasta acá se avisa y se pide confirmación. Más lejos, nada. */
export const DUPLICADO_AVISO_METROS = 30

/** Metros por grado de latitud. Constante; la longitud depende de la latitud. */
const METROS_POR_GRADO_LAT = 111320

/**
 * Saca los acentos. Espejo de `f_unaccent` de la base para el alfabeto que
 * usamos (castellano): NFD separa la letra del diacrítico y el replace lo tira.
 */
export function sinAcentos(texto: string): string {
  return texto.normalize('NFD').replace(/[̀-ͯ]/g, '')
}

/**
 * Clave de dirección para el bloqueo duro.
 *
 * Toma el primer segmento de la dirección formateada de Google ("Pje. Vera y
 * Aragon 2551, T4002AFE San Miguel de Tucumán, Tucumán, Argentina" → "pje vera
 * y aragon 2551"), le saca acentos, pasa todo lo que no es alfanumérico a un
 * espacio y colapsa.
 *
 * Devuelve `null` si la clave no tiene ningún dígito: sin altura no identifica
 * una puerta, identifica un barrio entero.
 */
export function claveDireccionConAltura(direccion: string | null | undefined): string | null {
  if (!direccion) return null
  const primerSegmento = direccion.split(',')[0] ?? ''
  const clave = sinAcentos(primerSegmento)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim()
  if (!clave || !/[0-9]/.test(clave)) return null
  return clave
}

/** Nombre normalizado: sin acentos, minúsculas, sin puntuación, sin espacios de más. */
export function normalizarNombre(nombre: string | null | undefined): string {
  if (!nombre) return ''
  return sinAcentos(nombre)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim()
}

/** Tokens del nombre normalizado, sin repetidos. */
export function tokensNombre(nombre: string | null | undefined): string[] {
  const norm = normalizarNombre(nombre)
  if (!norm) return []
  return Array.from(new Set(norm.split(' ')))
}

export type RelacionNombre = 'igual' | 'subconjunto' | 'distinto'

/**
 * Compara dos nombres. `igual` = misma cadena normalizada (bloqueo).
 * `subconjunto` = todos los tokens de uno están en el otro (aviso).
 */
export function compararNombres(a: string | null | undefined, b: string | null | undefined): RelacionNombre {
  const na = normalizarNombre(a)
  const nb = normalizarNombre(b)
  if (!na || !nb) return 'distinto'
  if (na === nb) return 'igual'

  const ta = tokensNombre(na)
  const tb = tokensNombre(nb)
  const contiene = (grande: string[], chico: string[]): boolean =>
    chico.length > 0 && chico.every(t => grande.includes(t))
  if (contiene(tb, ta) || contiene(ta, tb)) return 'subconjunto'
  return 'distinto'
}

/**
 * Semiejes en grados de un box que cubre `metros` alrededor de `lat`.
 *
 * Existe para poder seguir usando `idx_clientes_coordenadas` como prefiltro: se
 * calcula por eje, porque un grado de longitud mide menos cuanto más lejos del
 * ecuador (en Tucumán, ~89 km contra los 111 km de la latitud). El box es sólo
 * el prefiltro; la decisión la toma la distancia haversine.
 */
export function boxParaRadio(lat: number, metros: number): { dlat: number; dlng: number } {
  const dlat = metros / METROS_POR_GRADO_LAT
  // cos(lat) se va a 0 en los polos; el clamp evita un box infinito.
  const cos = Math.max(Math.cos((lat * Math.PI) / 180), 0.01)
  return { dlat, dlng: metros / (METROS_POR_GRADO_LAT * cos) }
}

export interface CandidatoDuplicado {
  id: string
  razon_social?: string | null
  nombre_fantasia?: string | null
  direccion?: string | null
  latitud?: number | null
  longitud?: number | null
  activo?: boolean
}

export interface EntradaDuplicado {
  razon_social?: string | null
  nombre_fantasia?: string | null
  direccion?: string | null
  latitud?: number | null
  longitud?: number | null
}

export type MotivoDuplicado =
  | 'direccion'
  | 'punto'
  | 'nombre_igual'
  | 'distancia'
  | 'nombre_subconjunto'

export interface VeredictoDuplicado {
  bloquea: boolean
  /** Pide confirmación explícita del usuario. Nunca junto con `bloquea`. */
  avisa: boolean
  motivo: MotivoDuplicado | null
  /** Metros al candidato, redondeado a un decimal. `null` si el motivo no es geográfico. */
  distancia_m: number | null
  candidato: CandidatoDuplicado | null
}

const SIN_HALLAZGO: VeredictoDuplicado = {
  bloquea: false,
  avisa: false,
  motivo: null,
  distancia_m: null,
  candidato: null,
}

function redondearMetros(m: number): number {
  return Math.round(m * 10) / 10
}

function distanciaA(entrada: EntradaDuplicado, c: CandidatoDuplicado): number | null {
  if (entrada.latitud == null || entrada.longitud == null) return null
  if (c.latitud == null || c.longitud == null) return null
  return haversineMeters(
    { lat: entrada.latitud, lng: entrada.longitud },
    { lat: c.latitud, lng: c.longitud },
  )
}

/**
 * Compara razón social y nombre de fantasía de los dos lados, todos contra
 * todos: el 938 tenía "Ricardo" de razón social y "López Ricardo " de fantasía,
 * y el 382 "Lopez Ricardo" de razón social. El par que bloquea es cruzado.
 */
function relacionEntre(entrada: EntradaDuplicado, c: CandidatoDuplicado): RelacionNombre {
  const izq = [entrada.razon_social, entrada.nombre_fantasia]
  const der = [c.razon_social, c.nombre_fantasia]
  let mejor: RelacionNombre = 'distinto'
  for (const a of izq) {
    for (const b of der) {
      const r = compararNombres(a, b)
      if (r === 'igual') return 'igual'
      if (r === 'subconjunto') mejor = 'subconjunto'
    }
  }
  return mejor
}

/**
 * El criterio completo. `candidatos` son clientes de la MISMA sucursal,
 * incluidos los inactivos (migs 199/200: si el de esa puerta está desactivado
 * lo que corresponde es reactivarlo, no clonarlo), y sin el que se está
 * editando.
 */
export function clasificarDuplicado(
  entrada: EntradaDuplicado,
  candidatos: CandidatoDuplicado[],
): VeredictoDuplicado {
  const clave = claveDireccionConAltura(entrada.direccion)

  // --- Bloqueo 1: misma dirección con altura ---------------------------
  if (clave) {
    const porDireccion = candidatos.find(c => claveDireccionConAltura(c.direccion) === clave)
    if (porDireccion) {
      const d = distanciaA(entrada, porDireccion)
      return {
        bloquea: true,
        avisa: false,
        motivo: 'direccion',
        distancia_m: d == null ? null : redondearMetros(d),
        candidato: porDireccion,
      }
    }
  }

  // --- Candidatos con distancia, del más cercano al más lejano ---------
  const conDistancia = candidatos
    .map(c => ({ c, d: distanciaA(entrada, c) }))
    .filter((x): x is { c: CandidatoDuplicado; d: number } => x.d != null)
    .sort((a, b) => a.d - b.d)

  // --- Bloqueo 2: el mismo punto ---------------------------------------
  const mismoPunto = conDistancia[0]
  if (mismoPunto && mismoPunto.d < DUPLICADO_BLOQUEO_METROS) {
    return {
      bloquea: true,
      avisa: false,
      motivo: 'punto',
      distancia_m: redondearMetros(mismoPunto.d),
      candidato: mismoPunto.c,
    }
  }

  // --- Bloqueo 3: mismo nombre exacto ----------------------------------
  const porNombre = candidatos.find(c => relacionEntre(entrada, c) === 'igual')
  if (porNombre) {
    const d = distanciaA(entrada, porNombre)
    return {
      bloquea: true,
      avisa: false,
      motivo: 'nombre_igual',
      distancia_m: d == null ? null : redondearMetros(d),
      candidato: porNombre,
    }
  }

  // --- Aviso 1: hay alguien cerca --------------------------------------
  if (mismoPunto && mismoPunto.d <= DUPLICADO_AVISO_METROS) {
    return {
      bloquea: false,
      avisa: true,
      motivo: 'distancia',
      distancia_m: redondearMetros(mismoPunto.d),
      candidato: mismoPunto.c,
    }
  }

  // --- Aviso 2: un nombre contenido en el otro -------------------------
  const porTokens = candidatos.find(c => relacionEntre(entrada, c) === 'subconjunto')
  if (porTokens) {
    const d = distanciaA(entrada, porTokens)
    return {
      bloquea: false,
      avisa: true,
      motivo: 'nombre_subconjunto',
      distancia_m: d == null ? null : redondearMetros(d),
      candidato: porTokens,
    }
  }

  return SIN_HALLAZGO
}

// ---------------------------------------------------------------------------
// El guard rige el alta y la mudanza, no cada edición
// ---------------------------------------------------------------------------

/**
 * Los cinco campos que el criterio mira. Todo lo demás de un cliente
 * —preventista, teléfono, horarios, crédito, zona— es invisible para el
 * veredicto.
 */
export interface IdentidadDuplicado {
  razon_social?: string | null
  nombre_fantasia?: string | null
  direccion?: string | null
  latitud?: number | null
  longitud?: number | null
}

/** Coordenada comparable: `undefined`, `null` y un número basura son lo mismo. */
function coordenada(v: number | string | null | undefined): number | null {
  if (v == null || v === '') return null
  const n = Number(v)
  return Number.isFinite(n) ? n : null
}

/**
 * Los nombres de un cliente como los ve el criterio: un CONJUNTO, no dos
 * campos. `relacionEntre` cruza los cuatro pares y se queda con el más fuerte,
 * así que el veredicto sólo depende de qué nombres hay, no de en qué casillero
 * está cada uno. Intercambiar razón social y fantasía, o rellenar una razón
 * social vacía con la fantasía —que es lo que hace el guardado—, no mueve nada.
 */
function nombresComparables(identidad: IdentidadDuplicado): string {
  const nombres = [identidad.razon_social, identidad.nombre_fantasia]
    .map(normalizarNombre)
    .filter(n => n !== '')
  return Array.from(new Set(nombres)).sort().join('|')
}

/**
 * ¿La edición cambia algo que el criterio pueda ver?
 *
 * El guard rige el ALTA y la MUDANZA, no cada edición. Un cliente que convive
 * con un vecino de nombre parecido ya convivía con él antes de que le tocaras
 * el preventista: preguntar de nuevo ahí no evita ningún duplicado. Es la misma
 * forma que la compra mínima (migs 204/205): la política se aplica al alta, no
 * retroactivamente. La regla 1 ya lo decía de sí misma en la mig 250 —"la clave
 * ya se repite en 19 grupos de la base, la regla rige el alta"—, pero sólo el
 * alta la respetaba.
 *
 * Y no era sólo ruido: medido sobre prod, 375 clientes tenían al menos un vecino
 * de nombre solapado —el aviso saltaba en CADA edición— y 133 caían en una regla
 * de bloqueo (116 por nombre idéntico, 20 por compartir puerta). Esos 133 no se
 * podían editar en absoluto: ni el teléfono, ni el horario, ni el preventista.
 *
 * Compara por lo que el criterio realmente mira —los nombres normalizados, la
 * clave de dirección con altura y las coordenadas—, no por el texto crudo:
 * escribir "CHICLANA 1895," donde decía "Chiclana 1895" no puede cambiar
 * ningún veredicto. Una dirección sin altura no entra al criterio, así que
 * cambiarla por otra sin altura tampoco cuenta.
 */
export function cambiaIdentidadDuplicado(
  antes: IdentidadDuplicado,
  despues: IdentidadDuplicado,
): boolean {
  return (
    nombresComparables(antes) !== nombresComparables(despues) ||
    claveDireccionConAltura(antes.direccion) !== claveDireccionConAltura(despues.direccion) ||
    coordenada(antes.latitud) !== coordenada(despues.latitud) ||
    coordenada(antes.longitud) !== coordenada(despues.longitud)
  )
}

// ---------------------------------------------------------------------------
// El veredicto tal como lo devuelve la RPC, y su texto
// ---------------------------------------------------------------------------

/**
 * Lo que devuelve `verificar_duplicado_cliente` (mig 250).
 *
 * `cliente_visible` viene en null cuando la RLS le tapa ese cliente al caller:
 * la RPC es SECURITY DEFINER y lo ve, pero decirle quién es sería filtrar por
 * la ventana lo que la policy tapa por la puerta (#543). En ese caso el mensaje
 * dice cuántos metros y nada más, y la RPC le avisa a administración.
 */
export interface VeredictoDuplicadoRPC {
  bloquea: boolean
  avisa: boolean
  motivo: MotivoDuplicado | null
  distancia_m: number | null
  cliente_visible: { id: number | string; nombre: string; activo: boolean } | null
}

/**
 * "No hay nada que ver acá". Lo devuelve el caller que se ahorra la RPC porque
 * la edición no toca nada que el criterio mire (`cambiaIdentidadDuplicado`).
 */
export const SIN_DUPLICADO_RPC: VeredictoDuplicadoRPC = {
  bloquea: false,
  avisa: false,
  motivo: null,
  distancia_m: null,
  cliente_visible: null,
}

export interface MensajeDuplicado {
  titulo: string
  mensaje: string
}

const SIN_IDENTIDAD =
  'No está en tu cartera, así que no podemos mostrarte cuál es. ' +
  'Ya le avisamos a administración para que lo revise.'

/**
 * El texto que ve el usuario. Vive acá, con el criterio, y no adentro del modal:
 * el mismo veredicto lo muestran el modal (confirmación) y `createCliente`
 * (última línea de defensa), y tienen que decir lo mismo.
 */
export function mensajeDuplicado(v: VeredictoDuplicadoRPC): MensajeDuplicado {
  const vecino = v.cliente_visible
  const nombre = vecino ? `"${vecino.nombre}" (#${vecino.id})` : null
  const metros = v.distancia_m == null ? null : `${v.distancia_m.toString().replace('.', ',')} m`

  // Un cliente inactivo en esa puerta se reactiva, no se clona: es lo que
  // originó los 9 pedidos huérfanos de la mig 199.
  if (vecino && vecino.activo === false) {
    return {
      titulo: 'Ese cliente ya existe, pero está inactivo',
      mensaje:
        `${nombre} ya está cargado en esta sucursal y está desactivado. ` +
        'Activá "Ver inactivos" en el panel de clientes y reactivalo, así conserva su historial.',
    }
  }

  switch (v.motivo) {
    case 'direccion':
      return {
        titulo: 'Ya hay un cliente en esa dirección',
        mensaje: nombre
          ? `${nombre} está cargado en la misma dirección. ` +
            'Si de verdad es otro comercio en la misma puerta, agregale el local a la dirección ' +
            '(por ejemplo "Berutti 399 Local 2") y volvé a intentar.'
          : `Ya hay un cliente cargado en esa misma dirección. ${SIN_IDENTIDAD}`,
      }

    case 'punto':
      return {
        titulo: 'Ya hay un cliente en ese punto exacto',
        mensaje: nombre
          ? `${nombre} está a menos de un metro: es la misma puerta.`
          : `Ya hay un cliente en ese punto exacto. ${SIN_IDENTIDAD}`,
      }

    case 'nombre_igual':
      return {
        titulo: 'Ese nombre ya existe en esta sucursal',
        mensaje: nombre
          ? `${nombre} ya está cargado con ese mismo nombre.`
          : `Ya hay un cliente con ese mismo nombre. ${SIN_IDENTIDAD}`,
      }

    case 'distancia':
      return {
        titulo: 'Hay un cliente muy cerca',
        mensaje: nombre
          ? `${nombre} está a ${metros}. Puede ser el mismo comercio cargado dos veces. ` +
            '¿Seguro que es otro y querés crearlo igual?'
          : `Hay un cliente a ${metros}. ${SIN_IDENTIDAD} ` +
            '¿Seguro que es otro y querés crearlo igual?',
      }

    case 'nombre_subconjunto':
      return {
        titulo: 'Hay un cliente con un nombre parecido',
        mensaje: nombre
          ? `${nombre} tiene un nombre que se solapa con el que estás cargando. ` +
            '¿Seguro que es otro y querés crearlo igual?'
          : `Hay un cliente con un nombre que se solapa. ${SIN_IDENTIDAD} ` +
            '¿Seguro que es otro y querés crearlo igual?',
      }

    default:
      return { titulo: '', mensaje: '' }
  }
}
