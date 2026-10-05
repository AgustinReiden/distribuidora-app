/**
 * Las sugerencias de bonificación (#908) del borrador de compra: las promos del
 * proveedor elegido contra las líneas y los cargos que hay. Sólo lee; aceptar o
 * descartar va por el reducer (AGREGAR_CARGO_SUGERIDO / DESCARTAR_SUGERENCIA).
 */
import { useMemo } from 'react'
import { usePromocionesProveedorQuery } from './queries/usePromocionesProveedorQuery'
import { useCargoConceptosQuery } from './queries/useCargosCatalogoQuery'
import { conceptoPorNombre } from '../utils/medidasCargo'
import type { ConceptoCargo } from '../utils/medidasCargo'
import { sugerirBonificaciones } from '../utils/sugerenciasBonificacion'
import type { SugerenciaBonificacion } from '../utils/sugerenciasBonificacion'
import type { CompraState } from '../components/modals/ModalCompra.reducer'

export interface SugerenciasBonificacionCompra {
  sugerencias: SugerenciaBonificacion[]
  /** "Bonificación" del catálogo (mig 278), si está. */
  concepto: ConceptoCargo | null
}

export function useSugerenciasBonificacion(state: CompraState): SugerenciasBonificacionCompra {
  const proveedorId = state.usarProveedorNuevo ? null : (state.proveedorId ? String(state.proveedorId) : null)
  const { data: promos } = usePromocionesProveedorQuery(proveedorId)
  const { data: conceptos } = useCargoConceptosQuery()

  const sugerencias = useMemo(() => {
    if (!proveedorId || !promos || promos.length === 0) return []
    return sugerirBonificaciones({
      lineas: state.items.flatMap(i => (i.lineaId === undefined ? [] : [{
        lineaId: i.lineaId,
        productoId: String(i.productoId),
        cantidad: Number(i.cantidad) || 0,
        costoUnitario: Number(i.costoUnitario) || 0,
        bonificacion: Number(i.bonificacion) || 0,
      }])),
      cargos: state.cargos,
      promos,
      fechaCompra: state.fechaCompra,
      descartadas: state.sugerenciasDescartadas ?? [],
    })
  }, [proveedorId, promos, state.items, state.cargos, state.fechaCompra, state.sugerenciasDescartadas])

  const concepto = useMemo(
    () => conceptoPorNombre(conceptos ?? [], 'Bonificación') ?? null,
    [conceptos],
  )
  return { sugerencias, concepto }
}
