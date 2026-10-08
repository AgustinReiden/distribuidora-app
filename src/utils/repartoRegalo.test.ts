import { describe, it, expect } from 'vitest'
import {
  conservarRepartos,
  raizDeSustitucion,
  regaloParaEditar,
  resolverCadenaSustitucion,
  validarRepartoRegalo,
} from './repartoRegalo'

describe('validarRepartoRegalo', () => {
  it('un reparto válido suma exactamente la cantidad original', () => {
    const v = validarRepartoRegalo(
      [{ productoId: '1', cantidad: 5 }, { productoId: '2', cantidad: 10 }],
      15,
      '1',
    )
    expect(v).toMatchObject({ ok: true, asignado: 15, faltante: 0, esReparto: true })
  })

  it('en un reparto se puede quedar parte del sabor original', () => {
    expect(validarRepartoRegalo(
      [{ productoId: '9', cantidad: 6 }, { productoId: '2', cantidad: 8 }],
      14,
      '9',
    ).ok).toBe(true)
  })

  it('avisa cuánto falta asignar', () => {
    const v = validarRepartoRegalo(
      [{ productoId: '1', cantidad: 5 }, { productoId: '2', cantidad: 7 }],
      15,
      '1',
    )
    expect(v.ok).toBe(false)
    expect(v.faltante).toBe(3)
    expect(v.errores).toContain('Faltan asignar 3 de 15')
  })

  it('avisa cuando se pasa', () => {
    const v = validarRepartoRegalo(
      [{ productoId: '1', cantidad: 10 }, { productoId: '2', cantidad: 7 }],
      15,
      '1',
    )
    expect(v.faltante).toBe(-2)
    expect(v.errores[0]).toMatch(/Te pasaste por 2/)
  })

  it('rechaza productos repetidos, filas sin producto y cantidades en 0', () => {
    expect(validarRepartoRegalo(
      [{ productoId: '1', cantidad: 5 }, { productoId: '1', cantidad: 10 }], 15, '1',
    ).errores).toContain('Hay un producto repetido')
    expect(validarRepartoRegalo(
      [{ productoId: '', cantidad: 5 }, { productoId: '2', cantidad: 10 }], 15, '1',
    ).errores).toContain('Elegí un producto en cada fila')
    expect(validarRepartoRegalo(
      [{ productoId: '3', cantidad: 0 }, { productoId: '2', cantidad: 15 }], 15, '1',
    ).errores).toContain('Cada fila necesita una cantidad mayor a 0')
  })

  it('las partes de un reparto son enteras (la columna es integer)', () => {
    expect(validarRepartoRegalo(
      [{ productoId: '1', cantidad: 7.5 }, { productoId: '2', cantidad: 7.5 }], 15, '1',
    ).errores).toContain('Las cantidades del reparto tienen que ser enteras')
  })

  it('una sola fila es la sustitución de siempre: cantidad libre, producto distinto', () => {
    expect(validarRepartoRegalo([{ productoId: '2', cantidad: 12 }], 15, '1'))
      .toMatchObject({ ok: true, esReparto: false })
    expect(validarRepartoRegalo([{ productoId: '1', cantidad: 15 }], 15, '1').errores)
      .toContain('Elegí un producto distinto del actual')
  })
})

// Las filas vienen de la más nueva a la más vieja, como las trae la query.
describe('resolverCadenaSustitucion', () => {
  it('dos sustituciones del mismo original sin nada que las una: vale la primera, la cadena se recorre en orden', () => {
    // #1010 (decisión del dueño, 2026-10-08): siempre el SIGUIENTE eslabón.
    // Hasta la 304 ganaba la más nueva (80). Esta historia —la línea vuelve a
    // 314 sin una fila que lo registre— no la genera ningún camino del código:
    // sustituir_regalo_pedido anota como original el producto que tiene la línea.
    const r = resolverCadenaSustitucion([
      { promocion_id: 13, producto_original_id: 314, producto_sustituto_id: 80, cantidad_original: 14, cantidad_sustituta: 14 },
      { promocion_id: 13, producto_original_id: 314, producto_sustituto_id: 79, cantidad_original: 14, cantidad_sustituta: 14 },
    ], 13, 314, 14)
    expect(r).toEqual({ productoId: '79', cantidad: 14, pasos: 1 })
  })

  it('un reparto invalida las sustituciones anteriores de la promo y sus filas no reescriben nada', () => {
    const filas = [
      { promocion_id: 13, producto_original_id: 314, producto_sustituto_id: 314, cantidad_original: 14, cantidad_sustituta: 6, reparto_id: 'r1' },
      { promocion_id: 13, producto_original_id: 314, producto_sustituto_id: 80, cantidad_original: 14, cantidad_sustituta: 8, reparto_id: 'r1' },
      { promocion_id: 13, producto_original_id: 80, producto_sustituto_id: 79, cantidad_original: 14, cantidad_sustituta: 14 },
    ]
    // Con el LIMIT 1 de antes, 314 se reescribía a 80 y 80 a 79: el reparto colapsaba.
    expect(resolverCadenaSustitucion(filas, 13, 314, 6)).toEqual({ productoId: '314', cantidad: 6, pasos: 0 })
    expect(resolverCadenaSustitucion(filas, 13, 80, 8)).toEqual({ productoId: '80', cantidad: 8, pasos: 0 })
  })

  it('una sustitución POSTERIOR al reparto sigue valiendo', () => {
    const r = resolverCadenaSustitucion([
      { promocion_id: 13, producto_original_id: 80, producto_sustituto_id: 79, cantidad_original: 8, cantidad_sustituta: 8 },
      { promocion_id: 13, producto_original_id: 314, producto_sustituto_id: 80, cantidad_original: 14, cantidad_sustituta: 8, reparto_id: 'r1' },
    ], 13, 80, 8)
    expect(r).toEqual({ productoId: '79', cantidad: 8, pasos: 1 })
  })

  it('el reparto de una promo no toca las sustituciones de otra', () => {
    const r = resolverCadenaSustitucion([
      { promocion_id: 13, producto_original_id: 314, producto_sustituto_id: 80, cantidad_original: 14, cantidad_sustituta: 8, reparto_id: 'r1' },
      { promocion_id: 15, producto_original_id: 94, producto_sustituto_id: 92, cantidad_original: 2, cantidad_sustituta: 2 },
    ], 15, 94, 2)
    expect(r).toEqual({ productoId: '92', cantidad: 2, pasos: 1 })
  })

  // #965 · borde 3: con A→P→Q el regalo vigente es Q, no P.
  const cadena = [
    { id: 2, created_at: '2026-10-02T10:00:00Z', promocion_id: 13, producto_original_id: 'P', producto_sustituto_id: 'Q', cantidad_original: 19, cantidad_sustituta: 19 },
    { id: 1, created_at: '2026-10-01T10:00:00Z', promocion_id: 13, producto_original_id: 'A', producto_sustituto_id: 'P', cantidad_original: 6, cantidad_sustituta: 19 },
  ]

  it('sigue la cadena hasta el último sustituto y convierte la cantidad en cada paso', () => {
    expect(resolverCadenaSustitucion(cadena, 13, 'A', 6)).toEqual({ productoId: 'Q', cantidad: 19, pasos: 2 })
    // La venta cambió: 12 de A → 38 de P (por valor) → 38 de Q (misma cantidad).
    expect(resolverCadenaSustitucion(cadena, 13, 'A', 12)).toEqual({ productoId: 'Q', cantidad: 38, pasos: 2 })
  })

  it('un eslabón ANTERIOR al paso previo no continúa la cadena', () => {
    // P→Q es más vieja que A→P: cuando A se cambió por P, P→Q ya era historia.
    const filas = [
      { id: 2, created_at: '2026-10-02T10:00:00Z', promocion_id: 13, producto_original_id: 'A', producto_sustituto_id: 'P', cantidad_original: 6, cantidad_sustituta: 6 },
      { id: 1, created_at: '2026-10-01T10:00:00Z', promocion_id: 13, producto_original_id: 'P', producto_sustituto_id: 'Q', cantidad_original: 6, cantidad_sustituta: 6 },
    ]
    expect(resolverCadenaSustitucion(filas, 13, 'A', 6).productoId).toBe('P')
  })

  it('una vuelta A→P→A se corta sola y queda lo último que se eligió', () => {
    const filas = [
      { id: 2, created_at: '2026-10-02T10:00:00Z', promocion_id: 13, producto_original_id: 'P', producto_sustituto_id: 'A', cantidad_original: 6, cantidad_sustituta: 6 },
      { id: 1, created_at: '2026-10-01T10:00:00Z', promocion_id: 13, producto_original_id: 'A', producto_sustituto_id: 'P', cantidad_original: 6, cantidad_sustituta: 6 },
    ]
    expect(resolverCadenaSustitucion(filas, 13, 'A', 6)).toEqual({ productoId: 'A', cantidad: 6, pasos: 2 })
  })

  it('con la misma fecha desempata por id, como el server', () => {
    const filas = [
      { id: 1, created_at: '2026-10-01T10:00:00Z', promocion_id: 13, producto_original_id: 'A', producto_sustituto_id: 'P', cantidad_original: 6, cantidad_sustituta: 6 },
      { id: 2, created_at: '2026-10-01T10:00:00Z', promocion_id: 13, producto_original_id: 'P', producto_sustituto_id: 'Q', cantidad_original: 6, cantidad_sustituta: 6 },
    ]
    expect(resolverCadenaSustitucion(filas, 13, 'A', 6).productoId).toBe('Q')
  })

  it('una sustitución por la misma cantidad no escala aunque cambie la venta', () => {
    const filas = [{ promocion_id: 13, producto_original_id: 'A', producto_sustituto_id: 'B', cantidad_original: 6, cantidad_sustituta: 6 }]
    expect(resolverCadenaSustitucion(filas, 13, 'A', 12)).toEqual({ productoId: 'B', cantidad: 12, pasos: 1 })
  })

  // #1010: una cadena que vuelve a un producto anterior. Desde P se tomaba la
  // más nueva (P→R) y se salteaban P→Q y Q→P: el producto final salía bien,
  // pero la cantidad no (R×23 en vez de R×30).
  const vuelta = [
    { id: 4, created_at: '2026-10-04T10:00:00Z', promocion_id: 13, producto_original_id: 'P', producto_sustituto_id: 'R', cantidad_original: 25, cantidad_sustituta: 30 },
    { id: 3, created_at: '2026-10-03T10:00:00Z', promocion_id: 13, producto_original_id: 'Q', producto_sustituto_id: 'P', cantidad_original: 10, cantidad_sustituta: 25 },
    { id: 2, created_at: '2026-10-02T10:00:00Z', promocion_id: 13, producto_original_id: 'P', producto_sustituto_id: 'Q', cantidad_original: 19, cantidad_sustituta: 10 },
    { id: 1, created_at: '2026-10-01T10:00:00Z', promocion_id: 13, producto_original_id: 'A', producto_sustituto_id: 'P', cantidad_original: 6, cantidad_sustituta: 19 },
  ]

  it('una cadena que vuelve a un producto anterior recorre todos los eslabones en orden', () => {
    expect(resolverCadenaSustitucion(vuelta, 13, 'A', 6)).toEqual({ productoId: 'R', cantidad: 30, pasos: 4 })
  })

  it('una cadena que vuelve a la raíz y sigue también se recorre entera', () => {
    // El admin ajustó dos veces la cantidad del regalo original: 6→8 y 8→9.
    const filas = [
      { id: 2, created_at: '2026-10-02T10:00:00Z', promocion_id: 13, producto_original_id: 'A', producto_sustituto_id: 'A', cantidad_original: 8, cantidad_sustituta: 9 },
      { id: 1, created_at: '2026-10-01T10:00:00Z', promocion_id: 13, producto_original_id: 'A', producto_sustituto_id: 'A', cantidad_original: 6, cantidad_sustituta: 8 },
    ]
    expect(resolverCadenaSustitucion(filas, 13, 'A', 6)).toEqual({ productoId: 'A', cantidad: 9, pasos: 2 })
  })
})

describe('raizDeSustitucion / regaloParaEditar', () => {
  const cadena = [
    { id: 2, created_at: '2026-10-02T10:00:00Z', promocion_id: 13, producto_original_id: 'P', producto_sustituto_id: 'Q', cantidad_original: 19, cantidad_sustituta: 19 },
    { id: 1, created_at: '2026-10-01T10:00:00Z', promocion_id: 13, producto_original_id: 'A', producto_sustituto_id: 'P', cantidad_original: 6, cantidad_sustituta: 19 },
  ]

  it('el final de una cadena vuelve a su raíz', () => {
    expect(raizDeSustitucion(cadena, 13, 'Q')).toBe('A')
    expect(raizDeSustitucion(cadena, 13, 'A')).toBeNull()
    expect(raizDeSustitucion(cadena, 15, 'Q')).toBeNull()
  })

  it('un eslabón intermedio no es el final: no tiene raíz', () => {
    // P se sigue cambiando por Q: mandarlo como A lo convertiría en Q.
    expect(raizDeSustitucion(cadena, 13, 'P')).toBeNull()
  })

  it('el regalo ya sustituido se envía con la raíz y la cantidad de la promo, y se muestra convertido', () => {
    expect(regaloParaEditar(cadena, 13, 'Q', 12)).toEqual({
      envio: { productoId: 'A', cantidad: 12 },
      muestra: { productoId: 'Q', cantidad: 38, pasos: 2 },
    })
  })

  it('el regalo con el producto original se envía tal cual', () => {
    expect(regaloParaEditar(cadena, 13, 'A', 6)).toEqual({
      envio: { productoId: 'A', cantidad: 6 },
      muestra: { productoId: 'Q', cantidad: 19, pasos: 2 },
    })
  })

  it('una auto-sustitución al final de la cadena (P→P, ajuste de cantidad) se envía con la raíz', () => {
    // Patrón real (pedido 3351: 79→80 y después 80→80). La línea es P 18 y el
    // override de la edición devuelve P con la cantidad de la promo (6, en
    // unidades de A): mandarlo como P 6 dejaba P 6 en el server.
    const filas = [
      { id: 2, created_at: '2026-10-02T10:00:00Z', promocion_id: 13, producto_original_id: 'P', producto_sustituto_id: 'P', cantidad_original: 19, cantidad_sustituta: 18 },
      { id: 1, created_at: '2026-10-01T10:00:00Z', promocion_id: 13, producto_original_id: 'A', producto_sustituto_id: 'P', cantidad_original: 6, cantidad_sustituta: 19 },
    ]
    expect(regaloParaEditar(filas, 13, 'P', 6)).toEqual({
      envio: { productoId: 'A', cantidad: 6 },
      muestra: { productoId: 'P', cantidad: 18, pasos: 2 },
    })
  })

  it('una auto-sustitución sola (A→A, 6→8) ajusta la cantidad', () => {
    const filas = [{ id: 1, created_at: '2026-10-01T10:00:00Z', promocion_id: 13, producto_original_id: 'A', producto_sustituto_id: 'A', cantidad_original: 6, cantidad_sustituta: 8 }]
    expect(regaloParaEditar(filas, 13, 'A', 6)).toEqual({
      envio: { productoId: 'A', cantidad: 6 },
      muestra: { productoId: 'A', cantidad: 8, pasos: 1 },
    })
  })

  it('#1010: editar sin cambios una cadena que vuelve a un producto anterior deja R×30', () => {
    const filas = [
      { id: 4, created_at: '2026-10-04T10:00:00Z', promocion_id: 13, producto_original_id: 'P', producto_sustituto_id: 'R', cantidad_original: 25, cantidad_sustituta: 30 },
      { id: 3, created_at: '2026-10-03T10:00:00Z', promocion_id: 13, producto_original_id: 'Q', producto_sustituto_id: 'P', cantidad_original: 10, cantidad_sustituta: 25 },
      { id: 2, created_at: '2026-10-02T10:00:00Z', promocion_id: 13, producto_original_id: 'P', producto_sustituto_id: 'Q', cantidad_original: 19, cantidad_sustituta: 10 },
      { id: 1, created_at: '2026-10-01T10:00:00Z', promocion_id: 13, producto_original_id: 'A', producto_sustituto_id: 'P', cantidad_original: 6, cantidad_sustituta: 19 },
    ]
    expect(regaloParaEditar(filas, 13, 'R', 6)).toEqual({
      envio: { productoId: 'A', cantidad: 6 },
      muestra: { productoId: 'R', cantidad: 30, pasos: 4 },
    })
  })

  it('un regalo sin sustituciones queda como vino', () => {
    expect(regaloParaEditar([], 13, 'X', 6)).toEqual({
      envio: { productoId: 'X', cantidad: 6 },
      muestra: { productoId: 'X', cantidad: 6, pasos: 0 },
    })
  })
})

describe('conservarRepartos', () => {
  const aLinea = (p: { producto_id: string | number; cantidad: number; promocion_id?: string | number | null }, plantilla: { productoId: string; cantidad: number; promocionId?: string | number | null; nombre?: string }) => ({
    ...plantilla,
    productoId: String(p.producto_id),
    cantidad: p.cantidad,
  })

  it('con el total igual manda las líneas que ya tenía el pedido', () => {
    const { bonificaciones, repartosPerdidos } = conservarRepartos(
      [
        { productoId: '79', cantidad: 14, promocionId: 13 },
        { productoId: '94', cantidad: 2, promocionId: 15 },
      ],
      [
        { producto_id: 314, cantidad: 6, promocion_id: 13 },
        { producto_id: 80, cantidad: 4, promocion_id: 13 },
        { producto_id: 79, cantidad: 4, promocion_id: 13 },
        { producto_id: 94, cantidad: 2, promocion_id: 15 },
      ],
      aLinea,
    )
    expect(bonificaciones.map(b => [b.productoId, b.cantidad])).toEqual([
      ['314', 6], ['80', 4], ['79', 4], ['94', 2],
    ])
    expect(repartosPerdidos).toEqual([])
  })

  it('si la cantidad de la promo cambió va lo recalculado y se avisa', () => {
    const { bonificaciones, repartosPerdidos } = conservarRepartos(
      [{ productoId: '79', cantidad: 12, promocionId: 13 }],
      [
        { producto_id: 314, cantidad: 6, promocion_id: 13 },
        { producto_id: 80, cantidad: 8, promocion_id: 13 },
      ],
      aLinea,
    )
    expect(bonificaciones).toEqual([{ productoId: '79', cantidad: 12, promocionId: 13 }])
    expect(repartosPerdidos).toEqual(['13'])
  })

  it('una promo con una sola línea no se toca', () => {
    const calculadas = [{ productoId: '94', cantidad: 3, promocionId: 15 }]
    const r = conservarRepartos(calculadas, [{ producto_id: 94, cantidad: 2, promocion_id: 15 }], aLinea)
    expect(r.bonificaciones).toEqual(calculadas)
    expect(r.repartosPerdidos).toEqual([])
  })

  it('si se quitó la promo, no resucita sus líneas', () => {
    const r = conservarRepartos(
      [],
      [
        { producto_id: 314, cantidad: 6, promocion_id: 13 },
        { producto_id: 80, cantidad: 8, promocion_id: 13 },
      ],
      aLinea,
    )
    expect(r.bonificaciones).toEqual([])
  })
})
