/**
 * Parser tolerante del horario de atención escrito a mano.
 *
 * Los preventistas vinieron cargando `clientes.horarios_atencion` como texto
 * libre ("Lunes a sábado de 9 hs a 14 hrs y 17 hs a 21hs", "24 HS", "9 A 14").
 * Ese texto no sirve para rutear: el optimizador necesita franjas `HH:MM-HH:MM`.
 * Este módulo convierte lo escrito al formato canónico de [horariosCliente.ts]
 * más un bitmask de días, marcando qué tan confiable fue la conversión.
 *
 * Diseñado contra los 128 textos distintos que había en producción, no contra
 * casos inventados. De ahí salen las rarezas que contempla: el separador de
 * franjas puede ser "y", "y de", "de", "después" o "desde"; el cierre puede
 * venir como "00", "24", "1 AM" o "2" (cruce de medianoche); y hay locales que
 * declaran apertura sin cierre ("9 en adelante", "8:30 corrido").
 *
 * Regla de oro: ante la duda, `confianza: 'dudosa'`. Lo dudoso va a revisión
 * humana antes de tocar el ruteo; lo de confianza alta se aplica solo.
 */

import type { FranjaHoraria } from './horariosCliente';
import { horaAMinutos, validarFranjas } from './horariosCliente';

/** Bitmask de días, orden Lunes→Domingo. '1111110' = lunes a sábado. */
export type DiasAtencion = string;

export const DIAS_TODOS: DiasAtencion = '1111111';
export const DIAS_LUN_SAB: DiasAtencion = '1111110';
export const DIAS_LUN_VIE: DiasAtencion = '1111100';

export interface HorarioParseado {
  /** Bitmask L→D, o null si el texto no menciona días. */
  dias: DiasAtencion | null;
  /** Franjas en formato canónico. Vacío si no se pudo interpretar nada. */
  franjas: FranjaHoraria[];
  /** 'alta' se aplica sin revisar; 'dudosa' va a la pantalla de revisión. */
  confianza: 'alta' | 'dudosa';
  /** Por qué quedó dudosa (se muestra al revisor). */
  motivo?: string;
}

/**
 * Índice en el bitmask de cada día. Incluye las formas plurales explícitamente:
 * no se puede despluralizar quitando la "s" final porque lunes..viernes ya
 * terminan en "s" ("lunes" → "lune" no existe).
 */
const INDICE_DIA: Record<string, number> = {
  lunes: 0, martes: 1, miercoles: 2, jueves: 3, viernes: 4,
  sabado: 5, sabados: 5, domingo: 6, domingos: 6,
};

const NOMBRES_DIA = 'lunes|martes|miercoles|jueves|viernes|sabados|sabado|domingos|domingo';

/** "lunes a sabado", y también el typo real "lunes sabados" (sin la "a"). */
const RE_RANGO_DIAS = new RegExp(`\\b(${NOMBRES_DIA})\\s+(?:a\\s+)?(${NOMBRES_DIA})\\b`, 'i');
const RE_TODOS_LOS_DIAS = /\btodos\s+los\s+dias\b/i;

/**
 * Par "H[:MM] a H[:MM]", con las unidades opcionales que aparecen en los datos
 * ("9 hs a 14 hrs", "8:30 a 14", "8 a 1 am"). El sufijo am se captura para
 * detectar el cruce de medianoche.
 */
const RE_PAR_HORAS =
  /(\d{1,2})(?::(\d{2}))?\s*(?:hrs?|hs?)?\.?\s*(?:a|hasta)\s+(\d{1,2})(?::(\d{2}))?\s*(am|hrs?|hs?)?/gi;

/** Apertura declarada sin cierre: "9 en adelante", "8:30 corrido", "de 8hs corridos". */
const RE_APERTURA_ABIERTA =
  /(\d{1,2})(?::(\d{2}))?\s*(?:hrs?|hs?)?\s*(?:en\s+adelante|corridos?)/i;

/** "24 hs", "24 horas", "24/7", "de corrido" — sin ningún rango numérico. */
const RE_24H = /\b(24\s*(?:hrs?|hs?|horas?)|24\s*\/\s*7)\b|\bde\s+corrido\b|\bcorridos?\b/i;

/** Una hora suelta, último recurso: "Lunes a sábado de 14 hrs". */
const RE_HORA_SUELTA = /(\d{1,2})(?::(\d{2}))?\s*(?:hrs?|hs?)\b/i;

/** Normaliza para poder escribir regex simples: sin acentos, minúsculas, espacios colapsados. */
function normalizar(texto: string): string {
  return texto
    .normalize('NFD')
    .replace(/\p{M}/gu, '')
    .toLowerCase()
    // "8: a 00" → "8 a 00": dos puntos sueltos sin minutos detrás.
    .replace(/:(?!\d)/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/** Redondea a la media hora más cercana. Devuelve null si la hora es inválida. */
function aMediaHora(h: number, m: number): { hhmm: string; redondeado: boolean } | null {
  if (!Number.isFinite(h) || h < 0 || h > 24) return null;
  if (!Number.isFinite(m) || m < 0 || m > 59) return null;
  const redondeado = m !== 0 && m !== 30;
  let hh = h;
  let mm = m;
  if (redondeado) {
    if (m < 15) mm = 0;
    else if (m < 45) mm = 30;
    else { mm = 0; hh = h + 1; }
  }
  if (hh > 24 || (hh === 24 && mm !== 0)) return null;
  return { hhmm: `${String(hh).padStart(2, '0')}:${String(mm).padStart(2, '0')}`, redondeado };
}

interface ParHoras {
  apertura: string;
  cierre: string;
  dudoso: boolean;
  motivo?: string;
}

/**
 * Convierte un par crudo de horas a una franja canónica.
 *
 * El cierre es donde está toda la ambigüedad real de los datos:
 *  - "00" y "24" significan medianoche → "24:00".
 *  - "1 am"/"2 am" y en general cualquier cierre menor a la apertura significan
 *    que el local cruza la medianoche. Para el ruteo se recorta a "24:00":
 *    nadie reparte a las 2 de la mañana, y el formato canónico no admite más.
 */
function construirPar(
  hA: number, mA: number, hC: number, mC: number, sufijoCierre: string | undefined,
): ParHoras | null {
  const ap = aMediaHora(hA, mA);
  if (!ap) return null;

  const esAm = /^am$/i.test(sufijoCierre ?? '');
  // "a las 00" / "a las 24" = medianoche.
  const cierreEsMedianoche = (hC === 0 || hC === 24) && mC === 0;
  // Cruce de medianoche: cierra "antes" de abrir, o lo dice explícito con am.
  const cruzaMedianoche = !cierreEsMedianoche && (esAm || hC < hA);

  if (cierreEsMedianoche || cruzaMedianoche) {
    return {
      apertura: ap.hhmm,
      cierre: '24:00',
      dudoso: cruzaMedianoche || ap.redondeado,
      motivo: cruzaMedianoche
        ? 'El local cierra pasada la medianoche; se recortó a las 24:00 para el reparto.'
        : undefined,
    };
  }

  const ci = aMediaHora(hC, mC);
  if (!ci) return null;
  if (horaAMinutos(ap.hhmm) >= horaAMinutos(ci.hhmm)) return null;

  return {
    apertura: ap.hhmm,
    cierre: ci.hhmm,
    dudoso: ap.redondeado || ci.redondeado,
    motivo: ap.redondeado || ci.redondeado
      ? 'Se redondearon los minutos a la media hora más cercana.'
      : undefined,
  };
}

/** Extrae el bitmask de días y devuelve el texto sin esa parte. */
function extraerDias(texto: string): { dias: DiasAtencion | null; resto: string } {
  if (RE_TODOS_LOS_DIAS.test(texto)) {
    return { dias: DIAS_TODOS, resto: texto.replace(RE_TODOS_LOS_DIAS, ' ') };
  }

  const m = RE_RANGO_DIAS.exec(texto);
  if (!m) return { dias: null, resto: texto };

  const desde = INDICE_DIA[m[1].toLowerCase()];
  const hasta = INDICE_DIA[m[2].toLowerCase()];
  if (desde == null || hasta == null || hasta < desde) {
    return { dias: null, resto: texto.replace(RE_RANGO_DIAS, ' ') };
  }

  const bits = Array.from({ length: 7 }, (_, i) => (i >= desde && i <= hasta ? '1' : '0'));
  return { dias: bits.join(''), resto: texto.replace(RE_RANGO_DIAS, ' ') };
}

/**
 * Convierte texto libre a días + franjas canónicas.
 *
 * @param texto valor crudo de `clientes.horarios_atencion`.
 * @returns franjas vacías y confianza 'dudosa' si no se pudo interpretar nada.
 */
export function parseHorarioLibre(texto?: string | null): HorarioParseado {
  if (!texto || !texto.trim()) {
    return { dias: null, franjas: [], confianza: 'dudosa', motivo: 'Sin horario cargado.' };
  }

  const { dias, resto } = extraerDias(normalizar(texto));

  const franjas: FranjaHoraria[] = [];
  let dudoso = false;
  const motivos: string[] = [];
  let descartados = 0;

  // 1) Pares "H a H". Es el caso dominante.
  RE_PAR_HORAS.lastIndex = 0;
  let m: RegExpExecArray | null;
  while ((m = RE_PAR_HORAS.exec(resto)) !== null) {
    const par = construirPar(
      Number(m[1]), Number(m[2] ?? 0), Number(m[3]), Number(m[4] ?? 0), m[5],
    );
    if (!par) { descartados++; continue; }
    franjas.push({ apertura: par.apertura, cierre: par.cierre });
    if (par.dudoso) {
      dudoso = true;
      if (par.motivo) motivos.push(par.motivo);
    }
  }

  // 2) Apertura sin cierre declarado ("9 en adelante", "8:30 corrido").
  if (franjas.length === 0) {
    const ma = RE_APERTURA_ABIERTA.exec(resto);
    if (ma) {
      const ap = aMediaHora(Number(ma[1]), Number(ma[2] ?? 0));
      if (ap) {
        franjas.push({ apertura: ap.hhmm, cierre: '24:00' });
        dudoso = true;
        motivos.push('Dice que abre de corrido pero no aclara a qué hora cierra.');
      }
    }
  }

  // 3) "24 hs" / "de corrido" sin ninguna hora.
  if (franjas.length === 0 && RE_24H.test(resto)) {
    franjas.push({ apertura: '00:00', cierre: '24:00' });
    dudoso = true;
    motivos.push('Declarado como 24 horas / de corrido: confirmá que sea literal.');
  }

  // 4) Último recurso: una hora suelta ("Lunes a sábado de 14 hrs").
  if (franjas.length === 0) {
    const mh = RE_HORA_SUELTA.exec(resto);
    if (mh) {
      const ap = aMediaHora(Number(mh[1]), Number(mh[2] ?? 0));
      if (ap) {
        franjas.push({ apertura: ap.hhmm, cierre: '24:00' });
        dudoso = true;
        motivos.push('Solo se pudo interpretar una hora; falta el cierre.');
      }
    }
  }

  if (franjas.length === 0) {
    return {
      dias,
      franjas: [],
      confianza: 'dudosa',
      motivo: 'No se pudo interpretar ningún horario del texto.',
    };
  }

  if (descartados > 0) {
    dudoso = true;
    motivos.push('Hay partes del texto que no se pudieron interpretar.');
  }

  // Más de dos franjas suele ser un horario distinto por día
  // ("de 10 a 22:30 de lunes a viernes y sabados de 14 a 22:30"), que el
  // formato canónico no representa.
  if (franjas.length > 2) {
    dudoso = true;
    motivos.push('Se detectaron más de dos franjas: puede tener horarios distintos según el día.');
  }

  // Solapamientos e inconsistencias las decide el validador ya existente.
  const validacion = validarFranjas(franjas);
  if (!validacion.valido) {
    dudoso = true;
    motivos.push(validacion.errorSolapamiento ?? 'Las franjas detectadas se superponen.');
  }

  return {
    dias,
    franjas,
    confianza: dudoso ? 'dudosa' : 'alta',
    motivo: motivos.length > 0 ? motivos.join(' ') : undefined,
  };
}
