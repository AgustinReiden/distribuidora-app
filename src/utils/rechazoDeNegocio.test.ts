import { describe, it, expect, vi } from 'vitest'

// sesionVencida importa el cliente de Supabase, que sin .env no se puede crear.
vi.mock('../lib/supabase', () => ({ supabase: {} }))

import { RechazoDeNegocioError, esRechazoDeNegocio, rechazoEsTerminal } from './rechazoDeNegocio'

describe('rechazoEsTerminal', () => {
  it.each([
    'Producto Fideos está desactivado y no se puede vender',
    'El pedido no alcanza la compra mínima de $10.000. Faltan $500.',
    'El total enviado ($1) no coincide con la suma de los items ($80.000). El pedido no se creo.',
    'Producto 12 no encontrado',
  ])('rechazo de negocio determinista es terminal: %s', (m) => {
    expect(rechazoEsTerminal(new RechazoDeNegocioError(m))).toBe(true)
  })

  // #1112: el rechazo de crear_pedido_completo a un reparto del alta cargado
  // por quien no es admin. Una op encolada con el rol caído no se reintenta.
  // Si cambiás el texto en la migración, cambialo acá.
  it('el reparto del alta por un no-admin es terminal', () => {
    const m = 'Solo un admin puede repartir el regalo de una promo en varios productos al cargar el pedido. '
      + 'Cargalo con el regalo de la promo; el admin o el encargado lo reparte después desde el pedido.'
    expect(rechazoEsTerminal(new RechazoDeNegocioError(m))).toBe(true)
  })

  it('stock insuficiente no es terminal: puede entrar mercadería', () => {
    expect(rechazoEsTerminal(new RechazoDeNegocioError('Fideos: stock insuficiente (disponible 0)'))).toBe(false)
  })

  it('sesión vencida / sucursal indeterminada no es terminal', () => {
    expect(rechazoEsTerminal(new RechazoDeNegocioError('No se pudo determinar la sucursal activa'))).toBe(false)
  })

  it.each([
    new Error('Failed to fetch'),
    new Error('Error de base de datos'),
    { message: 'timeout', code: '' },
    null,
    'texto',
  ])('lo que no es rechazo de negocio nunca es terminal', (e) => {
    expect(rechazoEsTerminal(e)).toBe(false)
  })
})

describe('esRechazoDeNegocio', () => {
  it('reconoce la clase y un Error con el mismo name (otro bundle)', () => {
    expect(esRechazoDeNegocio(new RechazoDeNegocioError('x'))).toBe(true)
    const e = new Error('x'); e.name = 'RechazoDeNegocioError'
    expect(esRechazoDeNegocio(e)).toBe(true)
    expect(esRechazoDeNegocio(new Error('x'))).toBe(false)
  })
})
