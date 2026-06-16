/**
 * Utilidades para los horarios de atención y entrega del cliente.
 *
 * Los horarios se persisten como texto legible en columnas `text`
 * (`clientes.horarios_atencion`, `clientes.horario_entrega`) para que se
 * impriman tal cual en la hoja de ruta, la orden de preparación, el recibo y
 * la ficha del cliente. El formato es una o más franjas `HH:MM-HH:MM` unidas
 * por " y " (ej: "08:00-12:00 y 16:00-20:00").
 *
 * Reglas:
 * - Las horas se comparan SIEMPRE en minutos (nunca lexicográficamente).
 * - El cierre puede llegar a "24:00" (medianoche); la apertura va 00:00..23:30.
 * - Dos franjas adyacentes (08:00-12:00 y 12:00-16:00) NO se consideran solapadas.
 */

export interface FranjaHoraria {
  /** Hora de apertura "HH:MM" (00:00..23:30). */
  apertura: string;
  /** Hora de cierre "HH:MM" (00:30..24:00; "24:00" = medianoche). */
  cierre: string;
}

/** Separador entre franjas en el string persistido. */
const SEPARADOR_FRANJAS = ' y ';

/** Regex de una franja "HH:MM-HH:MM" (el cierre admite 24:00). */
const RE_FRANJA = /^([01]\d|2[0-3]):(00|30)-([01]\d|2[0-3]|24):(00|30)$/;

/**
 * Etiquetas prefijadas que usaba la versión anterior del formulario. Se mapean
 * a rangos para no perder los datos ya cargados al abrir el editor.
 */
const MAPA_LEGACY: Record<string, FranjaHoraria> = {
  'Mañana (08 a 13)': { apertura: '08:00', cierre: '13:00' },
  'Mediodía (12 a 16)': { apertura: '12:00', cierre: '16:00' },
  'Tarde (16 a 20)': { apertura: '16:00', cierre: '20:00' },
  'Noche (20 a 00)': { apertura: '20:00', cierre: '24:00' },
};

/**
 * Genera las opciones de hora seleccionables, en pasos de 30 min.
 * @param incluirMedianoche si es true agrega "24:00" al final (solo para cierres).
 * @returns ["00:00", "00:30", ..., "23:30"] (+ "24:00" opcional).
 */
export function generarOpcionesHora(incluirMedianoche = false): string[] {
  const opciones: string[] = [];
  for (let h = 0; h < 24; h++) {
    const hh = String(h).padStart(2, '0');
    opciones.push(`${hh}:00`, `${hh}:30`);
  }
  if (incluirMedianoche) opciones.push('24:00');
  return opciones;
}

/**
 * Convierte "HH:MM" a minutos desde medianoche. "24:00" → 1440.
 * @returns minutos, o NaN si el formato es inválido.
 */
export function horaAMinutos(hora: string): number {
  if (!/^([01]\d|2[0-4]):(00|30)$/.test(hora)) return NaN;
  const [h, m] = hora.split(':').map(Number);
  if (h === 24 && m !== 0) return NaN;
  return h * 60 + m;
}

/**
 * Parsea el string persistido a franjas. Tolerante: ignora los trozos que no
 * sean exactamente "HH:MM-HH:MM" (ej. etiquetas viejas o texto libre).
 */
export function parsearFranjas(valor?: string | null): FranjaHoraria[] {
  if (!valor) return [];
  return valor
    .split(SEPARADOR_FRANJAS)
    .map(t => t.trim())
    .filter(t => RE_FRANJA.test(t))
    .map(t => {
      const [apertura, cierre] = t.split('-');
      return { apertura, cierre };
    });
}

/**
 * Serializa franjas al string persistido, descartando filas incompletas
 * (sin apertura o sin cierre).
 */
export function serializarFranjas(franjas: FranjaHoraria[]): string {
  return franjas
    .filter(f => f.apertura && f.cierre)
    .map(f => `${f.apertura}-${f.cierre}`)
    .join(SEPARADOR_FRANJAS);
}

export interface ResultadoValidacionFranjas {
  valido: boolean;
  /** Mensaje de error por índice de fila (apertura ≥ cierre). */
  erroresPorFila: Record<number, string>;
  /** Mensaje si dos franjas se solapan (null si no hay solape). */
  errorSolapamiento: string | null;
}

/**
 * Valida que cada franja tenga apertura < cierre y que ninguna se solape.
 * Las filas incompletas (sin ambas horas) se ignoran. Dos franjas adyacentes
 * (una termina donde empieza la otra) NO se consideran solapadas.
 */
export function validarFranjas(franjas: FranjaHoraria[]): ResultadoValidacionFranjas {
  const erroresPorFila: Record<number, string> = {};

  // 1. apertura < cierre, por fila (solo filas completas).
  franjas.forEach((f, i) => {
    if (!f.apertura || !f.cierre) return;
    if (horaAMinutos(f.apertura) >= horaAMinutos(f.cierre)) {
      erroresPorFila[i] = 'La apertura debe ser anterior al cierre.';
    }
  });

  // 2. solapamiento entre filas completas y sin error propio.
  let errorSolapamiento: string | null = null;
  const completas = franjas
    .map((f, i) => ({ f, i }))
    .filter(({ f, i }) => f.apertura && f.cierre && !erroresPorFila[i]);
  for (let a = 0; a < completas.length && !errorSolapamiento; a++) {
    for (let b = a + 1; b < completas.length; b++) {
      const ia = horaAMinutos(completas[a].f.apertura);
      const fa = horaAMinutos(completas[a].f.cierre);
      const ib = horaAMinutos(completas[b].f.apertura);
      const fb = horaAMinutos(completas[b].f.cierre);
      // Sin solape ⟺ una termina antes o justo cuando empieza la otra.
      const sinSolape = ib >= fa || ia >= fb;
      if (!sinSolape) {
        errorSolapamiento = 'Las franjas de atención no pueden superponerse.';
        break;
      }
    }
  }

  return {
    valido: Object.keys(erroresPorFila).length === 0 && !errorSolapamiento,
    erroresPorFila,
    errorSolapamiento,
  };
}

export interface ConversionInicial {
  franjas: FranjaHoraria[];
  /** true si alguna etiqueta prefijada vieja fue convertida a rango. */
  huboLegacy: boolean;
  /** Trozos que no eran ni "HH:MM-HH:MM" ni etiqueta conocida. */
  sinReconocer: string[];
}

/**
 * Convierte el valor persistido (string) a franjas para inicializar el editor.
 * Reconoce tanto el formato nuevo "HH:MM-HH:MM" como las etiquetas viejas
 * (MAPA_LEGACY). Lo que no reconoce se devuelve en `sinReconocer` para poder
 * avisarlo sin perderlo.
 */
export function convertirHorarioInicial(valor?: string | null): ConversionInicial {
  const franjas: FranjaHoraria[] = [];
  const sinReconocer: string[] = [];
  let huboLegacy = false;

  if (!valor) return { franjas, huboLegacy, sinReconocer };

  for (const trozo of valor.split(SEPARADOR_FRANJAS).map(t => t.trim())) {
    if (!trozo) continue;
    if (RE_FRANJA.test(trozo)) {
      const [apertura, cierre] = trozo.split('-');
      franjas.push({ apertura, cierre });
    } else if (MAPA_LEGACY[trozo]) {
      franjas.push({ ...MAPA_LEGACY[trozo] });
      huboLegacy = true;
    } else {
      sinReconocer.push(trozo);
    }
  }

  return { franjas, huboLegacy, sinReconocer };
}
