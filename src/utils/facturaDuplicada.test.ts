import { describe, it, expect } from 'vitest'
import {
  normalizarNumeroFactura, numeroFacturaChequeable, mismoNumeroFactura,
  comprasMismaFactura, fechaCortaCompra, normalizarNombreProveedor,
} from './facturaDuplicada'
import type { FilaCompraFactura } from './facturaDuplicada'

describe('normalizarNumeroFactura', () => {
  it('saca la letra del tipo y los ceros de cada tramo (la factura 304)', () => {
    expect(normalizarNumeroFactura('A0005-00467758')).toEqual({ puntoVenta: '5', numero: '467758', digitos: 7 })
  })

  it('da lo mismo con espacios, guiones o sin la letra', () => {
    const esperado = normalizarNumeroFactura('A0005-00467758')
    expect(normalizarNumeroFactura('0005-00467758')).toEqual(esperado)
    expect(normalizarNumeroFactura(' 5 - 467758 ')).toEqual(esperado)
    expect(normalizarNumeroFactura('FC A 00005-467758')).toEqual(esperado)
  })

  it('parte un número pegado al estilo AFIP (8 dígitos de número)', () => {
    expect(normalizarNumeroFactura('000500467758')).toEqual({ puntoVenta: '5', numero: '467758', digitos: 7 })
  })

  it('un tramo corto no tiene punto de venta', () => {
    expect(normalizarNumeroFactura('467758')).toEqual({ puntoVenta: null, numero: '467758', digitos: 6 })
  })

  it('sin dígitos devuelve null', () => {
    expect(normalizarNumeroFactura('')).toBeNull()
    expect(normalizarNumeroFactura(null)).toBeNull()
    expect(normalizarNumeroFactura('sin número')).toBeNull()
  })
})

describe('numeroFacturaChequeable', () => {
  it('no chequea la basura de prod: "0000", "00006", "12"', () => {
    expect(numeroFacturaChequeable(normalizarNumeroFactura('0000'))).toBe(false)
    expect(numeroFacturaChequeable(normalizarNumeroFactura('00006'))).toBe(false)
    expect(numeroFacturaChequeable(normalizarNumeroFactura('12'))).toBe(false)
    expect(numeroFacturaChequeable(normalizarNumeroFactura('0001-0000'))).toBe(false)
  })

  it('desde 4 dígitos significativos sí', () => {
    expect(numeroFacturaChequeable(normalizarNumeroFactura('1234'))).toBe(true)
    expect(numeroFacturaChequeable(normalizarNumeroFactura('0003-00000012'))).toBe(false)
    expect(numeroFacturaChequeable(normalizarNumeroFactura('0003-00000123'))).toBe(true)
  })
})

describe('mismoNumeroFactura', () => {
  const n = (s: string) => normalizarNumeroFactura(s)!

  it('mismo número y punto de venta', () => {
    expect(mismoNumeroFactura(n('A0005-00467758'), n('5-467758'))).toBe(true)
  })

  it('otro punto de venta es otra factura', () => {
    expect(mismoNumeroFactura(n('0005-00467758'), n('0006-00467758'))).toBe(false)
  })

  it('si uno no trae punto de venta, alcanza con el número', () => {
    expect(mismoNumeroFactura(n('467758'), n('0005-00467758'))).toBe(true)
  })

  it('otro número no', () => {
    expect(mismoNumeroFactura(n('0005-00467758'), n('0005-00467759'))).toBe(false)
  })
})

describe('comprasMismaFactura', () => {
  const filas: FilaCompraFactura[] = [
    { id: 304, numero_factura: 'A0005-00467758', fecha_compra: '2026-10-01', proveedor_id: 7, estado: 'recibida' },
    { id: 305, numero_factura: '0005-00467758', fecha_compra: '2026-10-01', proveedor_id: 8, estado: 'recibida' },
    { id: 306, numero_factura: '0005-00467758', fecha_compra: '2026-10-01', proveedor_id: 7, estado: 'cancelada' },
    { id: 307, numero_factura: '0005-00467759', fecha_compra: '2026-10-01', proveedor_id: 7, estado: 'recibida' },
    { id: 308, numero_factura: '5-467758', fecha_compra: '2026-10-02', proveedor_id: null, proveedor_nombre: 'Línea Blanca SRL', estado: 'recibida' },
    { id: 309, numero_factura: '00006', fecha_compra: '2026-10-02', proveedor_id: 7, estado: 'recibida' },
  ]

  it('mismo proveedor por id, mismo número, no cancelada', () => {
    const r = comprasMismaFactura(filas, { proveedorId: '7', proveedorNombre: '', numeroFactura: '0005-467758' })
    expect(r.map(f => f.id)).toEqual([304])
  })

  it('sin id, compara el nombre sin tildes ni mayúsculas', () => {
    const r = comprasMismaFactura(filas, { proveedorId: null, proveedorNombre: '  linea   blanca srl', numeroFactura: 'A0005-00467758' })
    expect(r.map(f => f.id)).toEqual([308])
  })

  it('sin id usa también el nombre del proveedor vinculado', () => {
    const conEmbed: FilaCompraFactura[] = [
      { id: 1, numero_factura: '0001-00001234', fecha_compra: '2026-10-01', proveedor_id: 3, proveedor: { nombre: 'Manaos SA' } },
    ]
    expect(comprasMismaFactura(conEmbed, { proveedorId: '', proveedorNombre: 'MANAOS SA', numeroFactura: '1-1234' })).toHaveLength(1)
  })

  it('no chequea números con menos de 4 dígitos', () => {
    expect(comprasMismaFactura(filas, { proveedorId: '7', proveedorNombre: '', numeroFactura: '00006' })).toEqual([])
  })

  it('sin proveedor no hay contra qué comparar', () => {
    expect(comprasMismaFactura(filas, { proveedorId: null, proveedorNombre: ' ', numeroFactura: '0005-467758' })).toEqual([])
  })
})

describe('normalizarNombreProveedor', () => {
  it('saca tildes y colapsa espacios', () => {
    expect(normalizarNombreProveedor(' José  Farías ')).toBe('jose farias')
  })
})

describe('fechaCortaCompra', () => {
  it('dd/mm en el año en curso, con el año si es otro', () => {
    expect(fechaCortaCompra('2026-10-01', '2026-10-03')).toBe('01/10')
    expect(fechaCortaCompra('2025-12-31', '2026-10-03')).toBe('31/12/2025')
    expect(fechaCortaCompra(null, '2026-10-03')).toBe('')
  })
})
