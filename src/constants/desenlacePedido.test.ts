import { describe, expect, it } from 'vitest'
import { MOTIVOS_ADMINISTRATIVOS, MOTIVOS_CANCELACION_TODOS } from './desenlacePedido'

/**
 * Fixture congelado de la lista de motivos administrativos del `CASE` de
 * `jornadas_preventista` / `jornada_preventista_detalle` (mig 179, más
 * `falta_stock` en la 269). Misma idea que el de abajo: copia estática, para
 * que un cambio de un solo lado se note.
 */
const CASE_ADMINISTRATIVOS_MIG_269 = [
  'error_de_carga', 'prueba', 'duplicado', 'unifica_pedidos', 'cambio_de_cliente',
  'falta_stock',
] as const

describe('MOTIVOS_ADMINISTRATIVOS vs CASE de las jornadas del preventista', () => {
  it('coincide con la lista del SQL', () => {
    expect([...MOTIVOS_ADMINISTRATIVOS].sort()).toEqual([...CASE_ADMINISTRATIVOS_MIG_269].sort())
  })

  it('la falta de stock no cuenta como rechazo del preventista (#827)', () => {
    expect(MOTIVOS_ADMINISTRATIVOS).toContain('falta_stock')
  })

  it('todo motivo administrativo es un motivo válido del CHECK', () => {
    for (const m of MOTIVOS_ADMINISTRATIVOS) expect(MOTIVOS_CANCELACION_TODOS).toContain(m)
  })
})

/**
 * Fixture congelado del CHECK `pedidos_motivo_cancelacion_tipo_check` tal
 * como lo dejó la mig 175 (migrations/175_motivo_de_cancelacion_siempre_tipificado.sql),
 * más `falta_stock` (mig 269).
 * Es intencionalmente una copia estática, no un import de la migración: lo
 * que hay que detectar acá es que alguien agregó un motivo al front sin
 * agregarlo al CHECK (o viceversa), y eso sólo se nota si las dos listas
 * viven separadas. Si una futura migración cambia el CHECK, este fixture se
 * actualiza a mano en la misma migración — es la señal de que alguien lo miró.
 */
const CHECK_MOTIVO_CANCELACION_TIPO_MIG_175 = [
  'cerrado', 'sin_dinero', 'cliente_rechaza', 'ausente',
  'direccion_incorrecta', 'clima',
  'cliente_cancelo', 'error_de_carga', 'duplicado', 'unifica_pedidos',
  'prueba', 'cambio_de_cliente', 'otro',
  // mig 269 (#827)
  'falta_stock',
] as const

describe('MOTIVOS_CANCELACION_TODOS vs CHECK pedidos_motivo_cancelacion_tipo_check (mig 175)', () => {
  it('cubre exactamente los mismos valores que el CHECK de la base', () => {
    expect([...MOTIVOS_CANCELACION_TODOS].sort()).toEqual(
      [...CHECK_MOTIVO_CANCELACION_TIPO_MIG_175].sort(),
    )
  })

  it('no tiene valores repetidos', () => {
    expect(new Set(MOTIVOS_CANCELACION_TODOS).size).toBe(MOTIVOS_CANCELACION_TODOS.length)
  })
})
