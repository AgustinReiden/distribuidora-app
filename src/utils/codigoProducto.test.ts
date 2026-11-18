/**
 * El código de un producto es único por sucursal (decisión D31 del dueño, #1561), sin
 * mirar mayúsculas ni los espacios de los bordes: el índice único del server compara
 * `upper(btrim(codigo))`, igual que los rubros (`upper(btrim(nombre))`). Esto es su espejo.
 */
import { describe, it, expect } from 'vitest'
import {
  claveCodigoProducto,
  codigoParaGuardar,
  errorCodigoDuplicado,
  esCodigoDuplicadoDeBase,
  INDICE_CODIGO_PRODUCTO_UNICO,
  mismoCodigoProducto,
  patronCodigoProducto,
} from './codigoProducto'

describe('claveCodigoProducto (espejo de upper(btrim(codigo)))', () => {
  it.each([
    ['abc-1', 'ABC-1'],
    ['  0802  ', '0802'],
    [' Sku 12 ', 'SKU 12'],
    ['', ''],
    ['   ', ''],
  ])('«%s» → «%s»', (codigo, clave) => {
    expect(claveCodigoProducto(codigo)).toBe(clave)
  })

  it('vacío o null no tienen clave', () => {
    expect(claveCodigoProducto(null)).toBe('')
    expect(claveCodigoProducto(undefined)).toBe('')
  })

  it('btrim saca sólo espacios: un tabulador queda, como en el server', () => {
    expect(claveCodigoProducto('abc\t')).toBe('ABC\t')
  })
})

describe('mismoCodigoProducto', () => {
  it('chocan sin mirar mayúsculas ni los espacios de los bordes', () => {
    expect(mismoCodigoProducto('abc-1', 'ABC-1')).toBe(true)
    expect(mismoCodigoProducto(' 0802', '0802 ')).toBe(true)
  })

  it('el espacio de adentro sí cuenta', () => {
    expect(mismoCodigoProducto('AB 1', 'AB1')).toBe(false)
  })

  it('dos vacíos no chocan: un producto sin código no choca con nadie', () => {
    expect(mismoCodigoProducto('', '')).toBe(false)
    expect(mismoCodigoProducto('  ', null)).toBe(false)
    expect(mismoCodigoProducto(null, undefined)).toBe(false)
  })
})

describe('codigoParaGuardar', () => {
  it('se guarda sin los espacios de los bordes', () => {
    expect(codigoParaGuardar('  0802 ')).toBe('0802')
  })

  it('vacío o sólo espacios se guarda como null (sin código)', () => {
    expect(codigoParaGuardar('')).toBeNull()
    expect(codigoParaGuardar('   ')).toBeNull()
    expect(codigoParaGuardar(null)).toBeNull()
    expect(codigoParaGuardar(undefined)).toBeNull()
  })

  it('las mayúsculas quedan como se tipearon', () => {
    expect(codigoParaGuardar('abc-1')).toBe('abc-1')
  })
})

describe('patronCodigoProducto (para achicar los candidatos con ilike)', () => {
  it('el código sin bordes, con los comodines de LIKE escapados', () => {
    expect(patronCodigoProducto(' A_1% ')).toBe('A\\_1\\%')
    expect(patronCodigoProducto('C:\\X')).toBe('C:\\\\X')
  })

  it('null si no hay código que buscar', () => {
    expect(patronCodigoProducto('  ')).toBeNull()
    expect(patronCodigoProducto(null)).toBeNull()
  })
})

describe('esCodigoDuplicadoDeBase', () => {
  it('es el 23505 del índice único del código', () => {
    expect(esCodigoDuplicadoDeBase({
      code: '23505',
      message: `duplicate key value violates unique constraint "${INDICE_CODIGO_PRODUCTO_UNICO}"`,
    })).toBe(true)
  })

  it('otro 23505 no lo es', () => {
    expect(esCodigoDuplicadoDeBase({ code: '23505', message: 'duplicate key value violates unique constraint "productos_pkey"' })).toBe(false)
  })

  it('otro código de error no lo es', () => {
    expect(esCodigoDuplicadoDeBase({ code: '42501', message: INDICE_CODIGO_PRODUCTO_UNICO })).toBe(false)
    expect(esCodigoDuplicadoDeBase(null)).toBe(false)
  })
})

describe('errorCodigoDuplicado', () => {
  it('nombra el producto que ya lo tiene y dice qué hacer; status 409', () => {
    const e = errorCodigoDuplicado('0802', 'MANI JAMON x 1kg') as Error & { status?: number }
    expect(e.message).toMatch(/Ya existe un producto con código "0802".*MANI JAMON x 1kg.*Buscalo por nombre o código/s)
    expect(e.status).toBe(409)
  })

  it('sin el nombre (lo frenó el índice) igual dice qué hacer', () => {
    expect(errorCodigoDuplicado('0802').message).toMatch(/Ya existe un producto con código "0802" en esta sucursal.*Buscalo por nombre o código/s)
  })

  it('en la edición sugiere dejarle otro código', () => {
    expect(errorCodigoDuplicado('0802', 'ARROZ', true).message).toMatch(/dejale a este otro código/)
  })
})
