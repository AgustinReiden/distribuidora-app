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

  const resultado = parseFloat(str);
  return isNaN(resultado) ? 0 : resultado;
}
