/**
 * El tipo de documento de un cliente sale de su valor (B17, #1561 1561-b11).
 *
 * `clientes.cuit` guarda un CUIT (`XX-XXXXXXXX-X`) o un DNI en el formato de
 * almacenamiento de la app (`00-XXXXXXXX-0`, `dniToStorageFormat`), y ningún CUIT
 * empieza con 00: el valor alcanza para saber cuál es. El front nunca le mandó el
 * tipo a la base, y todos los clientes quedaron con el default 'CUIT'.
 *
 * Espejo de `clientes_tipo_documento_del_valor()` (el trigger de la base): si
 * cambia la regla de un lado, cambia del otro.
 */
export type TipoDocumentoCliente = 'CUIT' | 'DNI'

/** El relleno de un DNI vacío: el cliente no tiene documento. */
export const DOCUMENTO_RELLENO = '00-00000000-0'

const FORMATO_DNI = /^00-\d{8}-0$/

/** 'DNI' si el valor es el formato de almacenamiento de un DNI; si no, 'CUIT'. */
export function tipoDocumentoDelValor(cuit: string | null | undefined): TipoDocumentoCliente {
  if (!cuit || cuit === DOCUMENTO_RELLENO) return 'CUIT'
  return FORMATO_DNI.test(cuit) ? 'DNI' : 'CUIT'
}

/**
 * El documento como se guarda: vacío o el relleno quedan `null` (sin documento), y
 * el tipo sale del valor.
 */
export function documentoParaGuardar(cuit: string | null | undefined): {
  cuit: string | null
  tipo_documento: TipoDocumentoCliente
} {
  const valor = cuit && cuit !== DOCUMENTO_RELLENO ? cuit : null
  return { cuit: valor, tipo_documento: tipoDocumentoDelValor(valor) }
}
