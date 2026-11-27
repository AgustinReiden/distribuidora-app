/**
 * Paradas de una ruta cuya coordenada probablemente está mal (#1717).
 *
 * Cuando Google no encuentra la altura de una dirección (pasajes, calles poco
 * conocidas), el autocompletado devuelve el punto de la CALLE y la app le pega
 * al texto el número tipeado (`preservarAlturaEnDireccion`). El texto queda
 * bien y la coordenada no: dos locales a dos puertas salían a 1,5 km, y el
 * optimizador, que sólo ve coordenadas, metía tres paradas de otras calles en
 * el medio. Ningún algoritmo de ruteo arregla eso, así que se avisa al armar
 * la ruta, que es cuando todavía se puede corregir el pin.
 *
 * Dos señales, entre las paradas de la ruta:
 *  - `misma_coordenada`: dos direcciones distintas con la MISMA coordenada
 *    exacta. Es la huella del punto de la calle: Google da el mismo para
 *    cualquier altura que no conoce.
 *  - `lejos_en_la_misma_cuadra`: misma calle y localidad, alturas a no más de
 *    `ALTURAS_CERCANAS` números, y a más de `METROS_LEJOS` de distancia. Una de
 *    las dos está mal; no se puede saber cuál, así que se nombran las dos.
 */

/** Alturas a esta distancia o menos son "la misma cuadra" (o la de al lado). */
export const ALTURAS_CERCANAS = 100;

/** Más que esto, para dos alturas de la misma cuadra, no es real. */
export const METROS_LEJOS = 400;

export interface ParadaUbicada {
  id: string;
  direccion?: string | null;
  latitud?: number | string | null;
  longitud?: number | string | null;
}

export type TipoUbicacionSospechosa = 'misma_coordenada' | 'lejos_en_la_misma_cuadra';

export interface UbicacionSospechosa {
  tipo: TipoUbicacionSospechosa;
  /** Las dos paradas, en el orden en que vinieron. */
  ids: [string, string];
  /** Distancia en metros según las coordenadas guardadas (redondeada). */
  metros: number;
}

const PREFIJOS_VIA = /\b(pje|pasaje|av|avda|avenida|calle|gral|general|bv|bvard|boulevard|c)\b\.?/g;
const CODIGO_POSTAL = /^[a-z]?\d{4}[a-z]{0,3}$/;

function sinAcentos(s: string): string {
  return s.normalize('NFD').replace(/[̀-ͯ]/g, '');
}

function numero(v: number | string | null | undefined): number | null {
  if (v == null || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

interface DireccionPartida {
  /** Calle normalizada, sin tipo de vía ni altura. */
  calle: string;
  altura: number | null;
  /** Localidad normalizada (sin código postal). */
  localidad: string;
  /** Línea de la calle normalizada con la altura: identifica la dirección. */
  linea: string;
}

/** Parte "Pje. Benjamín Paz 298, T4000 San Miguel de Tucumán, …" en calle, altura y localidad. */
export function partirDireccion(direccion: string | null | undefined): DireccionPartida | null {
  if (!direccion) return null;
  const segmentos = sinAcentos(direccion).toLowerCase().split(',').map(s => s.trim());
  const primera = segmentos[0] ?? '';
  if (!primera) return null;

  const matchAltura = /(\d+)\s*$/.exec(primera);
  const altura = matchAltura ? Number(matchAltura[1]) : null;
  const calle = primera
    .replace(/(\d+)\s*$/, '')
    .replace(PREFIJOS_VIA, ' ')
    .replace(/[.\s]+/g, ' ')
    .trim();

  const localidad = (segmentos[1] ?? '')
    .split(/\s+/)
    .filter(t => t && !CODIGO_POSTAL.test(t))
    .join(' ');

  return { calle, altura, localidad, linea: `${calle} ${altura ?? ''}`.trim() };
}

/** Distancia en metros (equirectangular: sobra para distancias urbanas). */
function metrosEntre(aLat: number, aLng: number, bLat: number, bLng: number): number {
  const rad = Math.PI / 180;
  const x = (bLng - aLng) * rad * Math.cos(((aLat + bLat) / 2) * rad);
  const y = (bLat - aLat) * rad;
  return Math.sqrt(x * x + y * y) * 6_371_000;
}

/**
 * Pares de paradas cuya ubicación no cierra con su dirección.
 *
 * Dos pedidos del mismo cliente (misma dirección) no son sospechosos. Un par
 * que cumple las dos señales sale una sola vez, como `misma_coordenada`.
 */
export function ubicacionesSospechosas(paradas: ParadaUbicada[]): UbicacionSospechosa[] {
  const ubicadas = paradas.flatMap(p => {
    const lat = numero(p.latitud);
    const lng = numero(p.longitud);
    const dir = partirDireccion(p.direccion);
    return lat != null && lng != null && dir ? [{ id: p.id, lat, lng, dir }] : [];
  });

  const salida: UbicacionSospechosa[] = [];
  for (let i = 0; i < ubicadas.length; i++) {
    for (let j = i + 1; j < ubicadas.length; j++) {
      const a = ubicadas[i];
      const b = ubicadas[j];
      if (a.dir.linea === b.dir.linea && a.dir.localidad === b.dir.localidad) continue;
      const metros = metrosEntre(a.lat, a.lng, b.lat, b.lng);

      if (a.lat === b.lat && a.lng === b.lng) {
        salida.push({ tipo: 'misma_coordenada', ids: [a.id, b.id], metros: 0 });
        continue;
      }

      if (
        a.dir.calle !== '' &&
        a.dir.calle === b.dir.calle &&
        a.dir.localidad === b.dir.localidad &&
        a.dir.altura != null &&
        b.dir.altura != null &&
        Math.abs(a.dir.altura - b.dir.altura) <= ALTURAS_CERCANAS &&
        metros > METROS_LEJOS
      ) {
        salida.push({ tipo: 'lejos_en_la_misma_cuadra', ids: [a.id, b.id], metros: Math.round(metros) });
      }
    }
  }
  return salida;
}
