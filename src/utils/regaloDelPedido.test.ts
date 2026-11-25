import { describe, it, expect } from 'vitest'
import { regaloDelPedidoParaPromo } from './regaloDelPedido'

// N1 (tanda 6 bis de #1603): la promo daba R cuando nació el pedido; hoy da P.
const productos: Record<string, { id: string; categoria: string }> = {
  R: { id: 'R', categoria: 'Gaseosas' },
  S: { id: 'S', categoria: 'Gaseosas' },
  W: { id: 'W', categoria: 'Gaseosas' },
  X: { id: 'X', categoria: 'Perfumes' },
}
const porId = (id: string) => productos[id]
const R = productos.R

describe('regaloDelPedidoParaPromo', () => {
  it('un reparto R×2 + S×2 armado desde R vuelve a R, no al regalo de hoy', () => {
    const lineas = [
      { id: 10, producto_id: 'S', promocion_id: 'p', regalo_cadena_id: 'c2', es_bonificacion: true },
      { id: 11, producto_id: 'R', promocion_id: 'p', regalo_cadena_id: 'c1', es_bonificacion: true },
      { id: 9, producto_id: 'V', promocion_id: null, es_bonificacion: false },
    ]
    const sust = [{ promocion_id: 'p', producto_original_id: 'R', producto_sustituto_id: 'S', cantidad_sustituta: 2, cadena_id: 'c2' }]
    expect(regaloDelPedidoParaPromo(lineas, sust, 'p', R, porId)).toBe('R')
  })

  it('una línea sustituida vuelve a la raíz de su cadena', () => {
    const lineas = [{ id: 1, producto_id: 'W', promocion_id: 'p', regalo_cadena_id: 'c1', es_bonificacion: true }]
    const sust = [{ promocion_id: 'p', producto_original_id: 'R', producto_sustituto_id: 'W', cantidad_sustituta: 8, cadena_id: 'c1' }]
    expect(regaloDelPedidoParaPromo(lineas, sust, 'p', R, porId)).toBe('R')
  })

  it('una raíz del rubro de la referencia, también (el server la acepta por N1)', () => {
    const lineas = [{ id: 1, producto_id: 'S', promocion_id: 'p', es_bonificacion: true }]
    expect(regaloDelPedidoParaPromo(lineas, [], 'p', R, porId)).toBe('S')
  })

  it('el borde: la raíz es un regalo de otro rubro que eligió un admin → null (queda el regalo de hoy, como en la 545)', () => {
    const lineas = [
      { id: 1, producto_id: 'X', promocion_id: 'p', regalo_cadena_id: 'c1', es_bonificacion: true },
      { id: 2, producto_id: 'S', promocion_id: 'p', regalo_cadena_id: 'c2', es_bonificacion: true },
    ]
    expect(regaloDelPedidoParaPromo(lineas, [], 'p', R, porId)).toBeNull()
  })

  it('sin la referencia (la RPC es de admin y encargado) o sin líneas de la promo, null', () => {
    const lineas = [{ id: 1, producto_id: 'R', promocion_id: 'p', es_bonificacion: true }]
    expect(regaloDelPedidoParaPromo(lineas, [], 'p', null, porId)).toBeNull()
    expect(regaloDelPedidoParaPromo(lineas, [], 'otra', R, porId)).toBeNull()
  })
})
