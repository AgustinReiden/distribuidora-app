/**
 * T4 (#1710) · Lo que se corrige de los cobros de una rendición.
 *
 * - `corregir_cobro_rendicion`: la forma de pago de un cobro (admin; el encargado, en una abierta
 *   que no es de un encargado) y quién lo cobró (admin), con motivo. Sólo en una rendición abierta
 *   o en disconformidad: una cerrada se reabre.
 * - `cobrar_faltante_rendicion`: lo que el cliente paga después contra el faltante que se le cargó a
 *   un empleado (sólo admin). Le baja la deuda al empleado y, en efectivo, entra en la caja de quien
 *   lo recibió. `anular_cobro_faltante` lo deshace.
 */
import { supabase } from './base'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { argQuienCobro } from '../../utils/quienCobro'

const SIN_CONEXION = 'Sin conexión: no se pudo confirmar el cambio. Refrescá la rendición antes de volver a intentar: puede haber quedado hecho.'

export async function corregirCobroRendicion(input: {
  pagoId: number
  formaPago?: string | null
  cobradoPor?: string | null
  motivo: string
}): Promise<void> {
  const { error } = await supabase.rpc('corregir_cobro_rendicion', {
    p_pago_id: input.pagoId,
    p_forma_pago: input.formaPago || null,
    ...argQuienCobro(input.cobradoPor),
    p_motivo: input.motivo,
  })
  if (error) throw errorDeSupabase(error, SIN_CONEXION)
}

export async function cobrarFaltanteRendicion(input: {
  faltanteId: number
  monto: number
  formaPago: string
  cobradoPor?: string | null
  observacion?: string | null
  clave: string
}): Promise<void> {
  const { error } = await supabase.rpc('cobrar_faltante_rendicion', {
    p_faltante_id: input.faltanteId,
    p_monto: input.monto,
    p_forma_pago: input.formaPago,
    ...argQuienCobro(input.cobradoPor),
    p_observacion: input.observacion || null,
    p_clave: input.clave,
  })
  if (error) throw errorDeSupabase(error, SIN_CONEXION)
}
