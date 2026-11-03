// Las filas de `bot_digest_pendientes`, leídas y ordenadas para mandar.
//
// Desde #1387 la RPC devuelve también el resumen que tocaba AYER y no salió
// (el cron de GitHub no corrió desde la hora de la persona hasta la
// medianoche): un día atrás y no más (decisión del dueño, 02/11). Cada fila trae
// su `fecha` (el día resumido) y `atrasado`. Una RPC anterior no los trae: la
// fila es la de hoy, con la fecha de la corrida.

/** Una persona y una sucursal a la que le toca un resumen en esta corrida. */
export interface Pendiente {
  telegram_user_id: number;
  perfil_id: string;
  /** 'admin' o 'preventista' (mig 311). Decide qué resumen se arma. */
  rol: string;
  /** La sucursal resumida: una fila por cada sucursal asignada (#1309). */
  sucursal_id: number | null;
  sucursal_nombre: string | null;
  /** Secciones elegidas por esta persona. Ver telegram-digest/secciones.ts. */
  secciones: string[];
  /** YYYY-MM-DD — el día resumido: ayer, o anteayer si es un atrasado. */
  fecha: string;
  /** #1387: el resumen de ayer, que no salió y se recupera hoy. */
  atrasado: boolean;
}

/**
 * Normaliza la respuesta de la RPC. `fechaDeHoy` es la fecha resumida de la
 * corrida (reloj.ts): la de una fila que no trae la suya. Los atrasados van
 * primero, para que lleguen antes que el resumen de hoy.
 */
export function leerPendientes(data: unknown, fechaDeHoy: string): Pendiente[] {
  const filas = (Array.isArray(data) ? data : []) as Array<Record<string, unknown>>;
  const pendientes = filas.map((row): Pendiente => {
    const fecha = typeof row.fecha === "string" && row.fecha !== "" ? row.fecha : fechaDeHoy;
    return {
      telegram_user_id: Number(row.telegram_user_id),
      perfil_id: String(row.perfil_id),
      // Sin `rol` (una RPC anterior a la 311) es el admin de siempre.
      rol: row.rol == null ? "admin" : String(row.rol),
      sucursal_id: row.sucursal_id == null ? null : Number(row.sucursal_id),
      sucursal_nombre: row.sucursal_nombre == null ? null : String(row.sucursal_nombre),
      secciones: Array.isArray(row.secciones) ? row.secciones.map(String) : [],
      fecha,
      // Se deduce de la fecha y no se le cree a la fila: un "atrasado" con la
      // fecha de hoy no existe.
      atrasado: fecha < fechaDeHoy,
    };
  });
  return [...pendientes.filter((p) => p.atrasado), ...pendientes.filter((p) => !p.atrasado)];
}
