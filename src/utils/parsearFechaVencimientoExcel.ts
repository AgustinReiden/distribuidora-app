/**
 * Parsea la columna "Vencimiento" de un Excel de importación de compra.
 *
 * Devuelve `null` cuando la celda está vacía o no es una fecha reconocible,
 * para que el llamador trate eso como "sin vencimiento" (opcional, no
 * descarta la fila) en vez de "fila inválida" (ver ModalImportarCompra).
 *
 * Nunca construye un `Date` a partir del string para no correr un día por el
 * huso horario (ver la cabecera de utils/vencimientos.ts): todo se parsea con
 * regex y aritmética de string.
 */
export function parsearFechaVencimientoExcel(valor: string | number | null | undefined): string | null {
  if (valor === null || valor === undefined || valor === '') return null;

  const texto = String(valor).trim();
  if (!texto) return null;

  // ISO, con u sin hora/Z: 'YYYY-MM-DD' o 'YYYY-MM-DDTHH:mm:ss.sssZ'.
  const iso = /^(\d{4})-(\d{2})-(\d{2})/.exec(texto);
  if (iso) {
    return validar(iso[1], iso[2], iso[3]);
  }

  // dd/mm/aaaa o dd-mm-aaaa.
  const corto = /^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$/.exec(texto);
  if (corto) {
    return validar(corto[3], corto[2], corto[1]);
  }

  return null;
}

function validar(anio: string, mes: string, dia: string): string | null {
  const a = Number(anio);
  const m = Number(mes);
  const d = Number(dia);
  if (!Number.isFinite(a) || !Number.isFinite(m) || !Number.isFinite(d)) return null;
  if (m < 1 || m > 12 || d < 1 || d > 31) return null;

  const mm = String(m).padStart(2, '0');
  const dd = String(d).padStart(2, '0');
  return `${anio}-${mm}-${dd}`;
}
