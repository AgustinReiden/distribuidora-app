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

  // #1123: los rechazos de crear_pedido_completo y actualizar_pedido_items al
  // regalo de quien no es admin (producto fuera de la categoría del default,
  // cantidad por encima del tope, regalo sin promo, promo inexistente). Una op
  // encolada así no cambia con reintentar. Si cambiás el texto en la
  // migración, cambialo acá.
  it.each([
    'El regalo de la promo "Manaos 5+2" tiene que ser Manaos Cola 2,25L o un producto de su misma categoría. '
      + 'Solo un admin puede elegir otro producto. El pedido no se creó.',
    'El regalo de la promo "Manaos 5+2" no puede pasar de 4 con lo que lleva el pedido (vinieron 50). '
      + 'Recargá la app y volvé a cargarlo. El pedido no se creó.',
    'Una línea de regalo tiene que venir de una promoción (producto ID 12). El pedido no se creó.',
    'La promoción 99 no existe en esta sucursal. El pedido no se creó.',
    'El regalo de la promo "Manaos 5+2" tiene que ser Manaos Cola 2,25L o un producto de su misma categoría. '
      + 'Solo un admin puede elegir otro producto. El pedido no se modificó.',
    'El regalo de la promo "Manaos 5+2" no puede pasar de 4 con lo que lleva el pedido (vinieron 8). '
      + 'Recargá la app y volvé a cargarlo. El pedido no se modificó.',
  ])('el regalo fuera de la promo es terminal: %s', (m) => {
    expect(rechazoEsTerminal(new RechazoDeNegocioError(m))).toBe(true)
  })

  // #1125: registrar_salvedad sobre un pedido dado de baja (migración
  // 357_la_merma_baja_la_huella). Reintentarla no cambia nada: el pedido no vuelve.
  // Si cambiás el texto en la migración, cambialo acá.
  it('la salvedad sobre un pedido dado de baja es terminal', () => {
    const m = 'El pedido #123 fue dado de baja (cancelado o anulado): no admite salvedades.'
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
