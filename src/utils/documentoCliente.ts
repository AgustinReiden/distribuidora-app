/**
 * El tipo de documento de un cliente sale de su valor (B17, #1561 1561-b11).
 *
 * `clientes.cuit` guarda un CUIT (`XX-XXXXXXXX-X`) o un DNI de 7 u 8 cifras en el
 * formato de almacenamiento de la app (`00-XXXXXXXX-0`, `dniToStorageFormat`), y
 * ningún CUIT empieza con 00: el valor alcanza para saber cuál es. El front nunca le
 * mandó el tipo a la base, y todos los clientes quedaron con el default 'CUIT'.
 *
 * Espejo de `clientes_tipo_documento_del_valor()` (el trigger de la base) y del CHECK
 * `clientes_documento_con_su_tipo`: si cambia la regla de un lado, cambia del otro.
 */
export type TipoDocumentoCliente = 'CUIT' | 'DNI'

const FORMATO_DNI = /^00-(\d{8})-0$/

/** Sólo ceros (el relleno `00-00000000-0` de un documento vacío): no es un documento. */
function esRelleno(cuit: string): boolean {
  return /^0+$/.test(cuit.replace(/\D/g, ''))
}

/** `00-XXXXXXXX-0` con un DNI de 7 u 8 cifras (sin los ceros de adelante). */
export function esDniGuardado(cuit: string | null | undefined): boolean {
  const m = cuit ? FORMATO_DNI.exec(cuit) : null
  return !!m && /^\d{7,8}$/.test(m[1].replace(/^0+/, ''))
}

/** 'DNI' si el valor es el formato de almacenamiento de un DNI; si no, 'CUIT'. */
export function tipoDocumentoDelValor(cuit: string | null | undefined): TipoDocumentoCliente {
  return esDniGuardado(cuit) ? 'DNI' : 'CUIT'
}

/**
 * El documento como se guarda: vacío o sólo ceros quedan `null` (sin documento), y el
 * tipo sale del valor.
 */
export function documentoParaGuardar(cuit: string | null | undefined): {
  cuit: string | null
  tipo_documento: TipoDocumentoCliente
} {
  const valor = cuit && !esRelleno(cuit) ? cuit : null
  return { cuit: valor, tipo_documento: tipoDocumentoDelValor(valor) }
}
