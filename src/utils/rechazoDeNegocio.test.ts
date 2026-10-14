import { describe, it, expect, vi } from 'vitest'

// sesionVencida importa el cliente de Supabase, que sin .env no se puede crear.
vi.mock('../lib/supabase', () => ({ supabase: {} }))

import {
  RechazoDeNegocioError, esRechazoDeNegocio, rechazoEsTerminal, esRechazoDeRegalo, CODIGO_REGALO_FUERA_DE_PROMO,
} from './rechazoDeNegocio'

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

  // #1136/#1137: el regalo de una promo apagada, fuera de su vigencia, o de dos
  // promos excluyentes. Reintentar no cambia nada: la promo no se reactiva sola.
  // Si cambiás el texto en la migración (362_la_promo_vigente_y_excluyente),
  // cambialo acá.
  it.each(
    [
      'La promo "Manaos 5+2" está desactivada: su regalo ya no entra en un pedido nuevo. Recargá la app y volvé a cargarlo.',
      'La promo "Manaos 5+2" rige del 01/10/2026 al 12/10/2026: su regalo no entra en un pedido del 13/10/2026. '
        + 'Recargá la app y volvé a cargarlo.',
      'La promo "Manaos 5+2" rige desde el 14/10/2026: su regalo no entra en un pedido del 13/10/2026. '
        + 'Recargá la app y volvé a cargarlo.',
      // el alta con fecha futura dice además el día de carga
      'La promo "Manaos 5+2" rige desde el 15/10/2026: su regalo no entra en un pedido del 17/10/2026 '
        + 'cargado el 14/10/2026. Recargá la app y volvé a cargarlo.',
      // #1152: la edicion con fecha futura dice el dia de la edicion
      'La promo "Manaos 5+2" rige desde el 15/10/2026: su regalo no entra en un pedido del 17/10/2026 '
        + 'editado el 14/10/2026. Recargá la app y volvé a cargarlo.',
      'Las promos "Manaos 5+2" y "Manaos 2+1" son excluyentes y comparten productos de este pedido: '
        + 'lleva el regalo de una sola. Recargá la app y volvé a cargarlo.',
    ].flatMap(m => [m + ' El pedido no se creó.', m + ' El pedido no se modificó.']),
  )('la promo apagada, fuera de vigencia o excluyente es terminal: %s', (m) => {
    expect(rechazoEsTerminal(new RechazoDeNegocioError(m))).toBe(true)
  })

  // #1125: registrar_salvedad sobre un pedido dado de baja (migración
  // 357_la_merma_baja_la_huella). Reintentarla no cambia nada: el pedido no vuelve.
  // Si cambiás el texto en la migración, cambialo acá.
  it('la salvedad sobre un pedido dado de baja es terminal', () => {
    const m = 'El pedido #123 fue dado de baja (cancelado o anulado): no admite salvedades.'
    expect(rechazoEsTerminal(new RechazoDeNegocioError(m))).toBe(true)
  })

  // #1138 y #1139: el regalo con precio y el precio de venta bajo el piso de la
  // lista (migración 363_el_precio_lo_pone_la_lista). Reintentar no cambia el
  // precio que viene en el pedido. Si cambiás el texto en la migración,
  // cambialo acá.
  it.each(
    [
      'Un regalo va a precio 0: el regalo de Coca 2L vino a $5,00.',
      'El precio de Coca 2L ($0,01) está por debajo del que permite la lista para este pedido ($4.450,00). Solo un admin puede cargar otro precio.',
    ].flatMap(m => [m + ' El pedido no se creó.', m + ' El pedido no se modificó.']),
  )('el regalo con precio y el precio bajo el piso son terminales: %s', (m) => {
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

describe('esRechazoDeRegalo (#1153)', () => {
  it('reconoce el rechazo con el codigo del server', () => {
    const e = new RechazoDeNegocioError('La promo "X" está desactivada: ... El pedido no se creó.', CODIGO_REGALO_FUERA_DE_PROMO)
    expect(e.codigo).toBe('regalo_fuera_de_promo')
    expect(esRechazoDeRegalo(e)).toBe(true)
    // sigue siendo terminal: el reintento automatico no lo arregla
    expect(rechazoEsTerminal(e)).toBe(true)
  })

  it('un rechazo sin codigo, o con otro, no es de regalo aunque el texto hable de promos', () => {
    expect(esRechazoDeRegalo(new RechazoDeNegocioError('La promo "X" está desactivada: ...'))).toBe(false)
    expect(esRechazoDeRegalo(new RechazoDeNegocioError('El pedido no alcanza la compra minima', 'otro'))).toBe(false)
  })

  it('lo que no es rechazo de negocio no es de regalo', () => {
    const e = Object.assign(new Error('x'), { codigo: CODIGO_REGALO_FUERA_DE_PROMO })
    expect(esRechazoDeRegalo(e)).toBe(false)
    expect(esRechazoDeRegalo(null)).toBe(false)
  })
})
