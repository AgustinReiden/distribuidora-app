/**
 * Normaliza un valor numérico desde diferentes formatos regionales
 * ("1.500,50" argentino, "1,500.50" americano, con o sin símbolo de moneda).
 * Usado al parsear columnas de Excel en ModalImportarCompra.
 */
export function normalizarNumero(valor: string | number | null | undefined): number {
  if (valor === null || valor === undefined || valor === '') return 0;
  if (typeof valor === 'number') return isNaN(valor) ? 0 : valor;

  let str = String(valor).trim();
  str = str.replace(/[$€£¥]/g, '').trim();

  const ultimoPunto = str.lastIndexOf('.');
  const ultimaComa = str.lastIndexOf(',');

  // Formato europeo/argentino: 1.500,50
  if (ultimaComa > ultimoPunto) {
    str = str.replace(/\./g, '').replace(',', '.');
  }
  // Formato americano: 1,500.50
  else if (ultimoPunto > ultimaComa && ultimaComa !== -1) {
    str = str.replace(/,/g, '');
  }
  // Solo coma decimal: 1500,50
  else if (ultimaComa !== -1 && ultimoPunto === -1) {
    str = str.replace(',', '.');
  }
  // Solo puntos de miles, sin coma: "1.500", "12.345.678" (STK-8, #1516). Una celda
  // de texto con "1.500" es mil quinientos en una planilla argentina; parseFloat la
  // leía como 1,5 sin avisar. Un punto seguido de 1, 2 o más de 3 dígitos ("1.5",
  // "1.50", "1.5000"), o con un 0 adelante ("0.500"), sigue siendo decimal.
  else if (/^-?[1-9]\d{0,2}(\.\d{3})+$/.test(str)) {
    str = str.replace(/\./g, '');
  }

  const resultado = parseFloat(str);
  return isNaN(resultado) ? 0 : resultado;
}
