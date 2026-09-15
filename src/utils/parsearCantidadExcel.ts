/**
 * Parsea la columna "Cantidad" de un Excel de importación de compra.
 *
 * Devuelve `null` cuando la celda está vacía o no es numérica, para que el
 * llamador la trate como fila inválida en vez de asumir 1 unidad en silencio
 * (ver ModalImportarCompra).
 */
import { normalizarNumero } from './normalizarNumero';

export function parsearCantidadExcel(valor: string | number | null | undefined): number | null {
  if (valor === null || valor === undefined || valor === '') return null;

  if (typeof valor === 'number') {
    return Number.isFinite(valor) && valor > 0 ? Math.round(valor) : null;
  }

  const normalizado = normalizarNumero(valor);
  if (normalizado <= 0) return null;

  return Math.round(normalizado);
}
