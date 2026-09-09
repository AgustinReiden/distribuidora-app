import { describe, it, expect } from 'vitest'
import { emparejarRed, coincideBusqueda, tieneStock, type ProductoRed } from './stockRed'

const TUC = 1
const TP = 2

let seq = 0
function prod(sucursal_id: number, nombre: string, extra: Partial<ProductoRed> = {}): ProductoRed {
  seq += 1
  return {
    producto_id: seq,
    sucursal_id,
    sucursal_nombre: sucursal_id === TUC ? 'Tucuman' : 'Taco Pozo',
    nombre,
    codigo: null,
    categoria: 'GASEOSAS',
    stock: 10,
    costo_promedio: 100,
    costo_reposicion: 120,
    ultimo_tipo_compra: 'FC',
    precio: 200,
    ...extra,
  }
}

describe('emparejarRed', () => {
  it('empareja por código exacto aunque el nombre no coincida', () => {
    // Caso real: "ALFATUC BLANCO x 18 u" en Tucumán y "ALFATUC BLANCO DISPLAY
    // X 18" en Taco Pozo comparten código.
    const { emparejados, sinPar } = emparejarRed([
      prod(TUC, 'ALFATUC BLANCO x 18 u', { codigo: 'A100' }),
      prod(TP, 'ALFATUC BLANCO DISPLAY X 18', { codigo: 'A100' }),
    ], [TUC, TP])

    expect(sinPar).toHaveLength(0)
    expect(emparejados).toHaveLength(1)
    expect(emparejados[0].sucursales).toEqual([TUC, TP])
    expect(emparejados[0].porSucursal[TP]?.nombre).toBe('ALFATUC BLANCO DISPLAY X 18')
  })

  it('empareja por nombre exacto normalizado cuando no hay código', () => {
    // "PINDAPOY DURAZNO 200 cc x 18" vs "PINDAPOY DURAZNO 200 CC X 18".
    const { emparejados } = emparejarRed([
      prod(TUC, 'PINDAPOY DURAZNO 200 cc x 18'),
      prod(TP, '  PINDAPOY  DURAZNO   200 CC X 18 '),
    ], [TUC, TP])

    expect(emparejados).toHaveLength(1)
    expect(emparejados[0].nombre).toBe('PINDAPOY DURAZNO 200 cc x 18')
  })

  it('NO empareja por coincidencia parcial', () => {
    const { emparejados, sinPar } = emparejarRed([
      prod(TUC, 'MANAOS COLA 2.25 L'),
      prod(TP, 'MANAOS COLA 2.25 L X 6'),
    ], [TUC, TP])

    expect(emparejados).toHaveLength(0)
    expect(sinPar).toHaveLength(2)
    expect(sinPar.every((f) => f.ambiguo)).toBe(false)
  })

  it('el código manda sobre el nombre', () => {
    const { emparejados } = emparejarRed([
      prod(TUC, 'AGUA 1.5', { codigo: 'C1' }),
      prod(TP, 'OTRA COSA', { codigo: 'C1' }),
      prod(TP, 'AGUA 1.5', { codigo: 'C9' }),
    ], [TUC, TP])

    expect(emparejados).toHaveLength(1)
    expect(emparejados[0].porSucursal[TP]?.nombre).toBe('OTRA COSA')
  })

  it('un producto se empareja una sola vez: el segundo del mismo código queda sin par', () => {
    const { emparejados, sinPar } = emparejarRed([
      prod(TUC, 'SAL FINA x 500 g x 10 u', { codigo: 'S1' }),
      prod(TP, 'SAL FINA DISPLAY', { codigo: 'S1' }),
      prod(TP, 'SAL FINA SUELTA', { codigo: 'S1' }),
    ], [TUC, TP])

    expect(emparejados).toHaveLength(1)
    expect(sinPar.map((f) => f.nombre)).toEqual(['SAL FINA SUELTA'])
  })

  it('marca ambiguo y NO empareja cuando el código coincide con más de un candidato', () => {
    // productos.codigo no tiene UNIQUE: dos filas de Tucumán pueden compartirlo.
    const { emparejados, sinPar } = emparejarRed([
      prod(TUC, 'COLA 2.25 RETORNABLE', { codigo: 'D1' }),
      prod(TUC, 'COLA 2.25 DESCARTABLE', { codigo: 'D1' }),
      prod(TP, 'COLA 2.25', { codigo: 'D1' }),
    ], [TUC, TP])

    expect(emparejados).toHaveLength(0)
    expect(sinPar).toHaveLength(3)
    expect(sinPar.find((f) => f.nombre === 'COLA 2.25')?.ambiguo).toBe(true)
  })

  it('el código vacío no empareja con otro código vacío', () => {
    const { emparejados, sinPar } = emparejarRed([
      prod(TUC, 'UNO', { codigo: '' }),
      prod(TP, 'DOS', { codigo: '   ' }),
    ], [TUC, TP])

    expect(emparejados).toHaveLength(0)
    expect(sinPar).toHaveLength(2)
  })

  it('el producto que está en una sola sucursal queda en sinPar, no se pierde', () => {
    const { emparejados, sinPar } = emparejarRed([
      prod(TUC, 'A', { codigo: 'X' }),
      prod(TP, 'A', { codigo: 'X' }),
      prod(TP, 'SOLO EN TACO POZO'),
    ], [TUC, TP])

    expect(emparejados).toHaveLength(1)
    expect(sinPar.map((f) => f.nombre)).toEqual(['SOLO EN TACO POZO'])
    expect(sinPar[0].sucursales).toEqual([TP])
  })

  it('ningún producto se pierde ni se duplica', () => {
    const productos = [
      prod(TUC, 'A', { codigo: 'X' }), prod(TUC, 'B'), prod(TUC, 'C'),
      prod(TP, 'A', { codigo: 'X' }), prod(TP, 'D'),
    ]
    const { emparejados, sinPar } = emparejarRed(productos, [TUC, TP])
    const ids = [...emparejados, ...sinPar]
      .flatMap((f) => Object.values(f.porSucursal))
      .map((p) => p?.producto_id)

    expect(ids).toHaveLength(productos.length)
    expect(new Set(ids).size).toBe(productos.length)
  })

  it('sin orden de sucursales usa el orden de aparición', () => {
    const { emparejados } = emparejarRed([
      prod(TP, 'A', { codigo: 'X' }),
      prod(TUC, 'A', { codigo: 'X' }),
    ])

    expect(emparejados).toHaveLength(1)
    expect(emparejados[0].sucursales).toEqual([TP, TUC])
  })
})

describe('coincideBusqueda', () => {
  const [fila] = emparejarRed([
    prod(TUC, 'MANAOS COLA 2.25', { codigo: 'MC225', categoria: 'GASEOSAS' }),
    prod(TP, 'MANAOS COLA GRANDE', { codigo: 'MC225' }),
  ], [TUC, TP]).emparejados

  it('sin texto pasa todo', () => {
    expect(coincideBusqueda(fila, '   ')).toBe(true)
  })

  it('busca por nombre, código y categoría, sin distinguir mayúsculas', () => {
    expect(coincideBusqueda(fila, 'manaos')).toBe(true)
    expect(coincideBusqueda(fila, 'mc225')).toBe(true)
    expect(coincideBusqueda(fila, 'gaseosas')).toBe(true)
  })

  it('encuentra por el nombre de la OTRA sucursal', () => {
    expect(coincideBusqueda(fila, 'grande')).toBe(true)
  })

  it('no inventa coincidencias', () => {
    expect(coincideBusqueda(fila, 'cerveza')).toBe(false)
  })
})

describe('tieneStock', () => {
  it('alcanza con que una sucursal tenga stock', () => {
    const { emparejados } = emparejarRed([
      prod(TUC, 'A', { codigo: 'X', stock: 0 }),
      prod(TP, 'A', { codigo: 'X', stock: 5 }),
    ], [TUC, TP])
    expect(tieneStock(emparejados[0])).toBe(true)
  })

  it('el stock negativo cuenta como stock (hay que verlo, no esconderlo)', () => {
    const { sinPar } = emparejarRed([prod(TUC, 'A', { stock: -3 })], [TUC])
    expect(tieneStock(sinPar[0])).toBe(true)
  })

  it('todo en cero es sin stock', () => {
    const { emparejados } = emparejarRed([
      prod(TUC, 'A', { codigo: 'X', stock: 0 }),
      prod(TP, 'A', { codigo: 'X', stock: 0 }),
    ], [TUC, TP])
    expect(tieneStock(emparejados[0])).toBe(false)
  })
})
