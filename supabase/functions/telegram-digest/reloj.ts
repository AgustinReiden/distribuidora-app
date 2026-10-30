// La hora, el día y las fechas de una corrida del digest, en TZ Argentina.
//
// Es la mitad TS de "a quién le toca" (#1309): `bot_digest_pendientes` recibe
// la fecha resumida, la hora y el día de la semana que se calculan acá, y con
// eso decide. Se calcula UNA vez por corrida y desde el mismo instante: con un
// `new Date()` por dato, una corrida que cruza la medianoche podía pedir el
// "ayer" de un día y la hora del siguiente.
//
// Usamos Intl.DateTimeFormat con timeZone para que el resultado sea robusto
// frente a la TZ del runtime de Supabase (que es UTC, pero queremos el día del
// punto de vista de un argentino).

const TZ = "America/Argentina/Buenos_Aires";

export interface RelojDigest {
  /** YYYY-MM-DD — el día que se resume: ayer en Argentina. */
  fecha: string;
  /** YYYY-MM-DD — hoy en Argentina (vencimientos y aviso de atrasados). */
  hoy: string;
  /** 0..23 en Argentina. */
  hora: number;
  /** ISO: 1 = lunes … 7 = domingo, como `EXTRACT(ISODOW)` de Postgres. */
  dow: number;
}

export function relojDigest(ahora: Date = new Date()): RelojDigest {
  const hoy = fechaEnArgentina(ahora);
  return { fecha: diaAnterior(hoy), hoy, hora: horaEnArgentina(ahora), dow: diaIsoEnArgentina(ahora) };
}

function fechaEnArgentina(d: Date): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: TZ,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(d);
}

/** El día calendario anterior a un YYYY-MM-DD (sin TZ: es aritmética de fechas). */
function diaAnterior(fecha: string): string {
  const d = new Date(`${fecha}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() - 1);
  return d.toISOString().slice(0, 10);
}

/**
 * Hora (0..23). `hour12: false` da "24" a medianoche en vez de "00" en algunos
 * runtimes, asi que el 24 se normaliza a 0 — si no, nadie con `hora_local = 0`
 * recibiria nunca su digest.
 */
function horaEnArgentina(d: Date): number {
  const h = Number(
    new Intl.DateTimeFormat("en-GB", { timeZone: TZ, hour: "2-digit", hour12: false }).format(d),
  );
  return h % 24;
}

/**
 * Dia de la semana ISO: 1 = lunes … 7 = domingo. Coincide con
 * `EXTRACT(ISODOW)` de Postgres, que es contra lo que se guarda `dias_semana`.
 */
function diaIsoEnArgentina(d: Date): number {
  const dias: Record<string, number> = { Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7 };
  return dias[new Intl.DateTimeFormat("en-US", { timeZone: TZ, weekday: "short" }).format(d)] ?? 1;
}
