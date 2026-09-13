import { describe, expect, it } from 'vitest'
import { MOTIVOS_CANCELACION_TODOS } from './desenlacePedido'

/**
 * Fixture congelado del CHECK `pedidos_motivo_cancelacion_tipo_check` tal
 * como lo dejó la mig 175 (migrations/175_motivo_de_cancelacion_siempre_tipificado.sql).
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
