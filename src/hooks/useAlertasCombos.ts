/**
 * Las alertas de los combos vigentes de la sucursal activa (#1194), con la
 * forma de las del reporte gerencial. La cuenta es `alertasCombosParaReporte`
 * (la misma de las etiquetas del panel de combos), con los topes de
 * `politicas_comerciales` y los costos sólo si el rol los ve.
 */
import { useMemo } from 'react'
import { useCombosAdminQuery } from './queries/useCombosQuery'
import { useProductosQuery } from './queries/useProductosQuery'
import { usePoliticasComercialesQuery } from './queries/usePoliticasComercialesQuery'
import { useAuthData } from '../contexts/AuthDataContext'
import { puedeVerCostoProducto } from '../lib/permisos'
import { fechaLocalISO } from '../utils/formatters'
import { alertasCombosParaReporte, type AlertaReporteCombo, type ProductoParaAlertas } from '../utils/comboAlertas'
import { resolverLugares } from '../utils/comboCategorias'

const SIN_ALERTAS: AlertaReporteCombo[] = []

export function useAlertasCombos(enabled: boolean): AlertaReporteCombo[] {
  const { data: combos } = useCombosAdminQuery(enabled)
  const { data: productos } = useProductosQuery({ enabled })
  const { politicas } = usePoliticasComercialesQuery()
  const { perfil } = useAuthData()
  const verCostos = puedeVerCostoProducto(perfil?.rol)

  return useMemo(() => {
    if (!enabled || !combos || !productos || combos.length === 0) return SIN_ALERTAS
    const hoy = fechaLocalISO()
    const vigentes = combos.filter(c => c.activo && c.fechaInicio <= hoy && (!c.fechaFin || c.fechaFin >= hoy))
    if (vigentes.length === 0) return SIN_ALERTAS
    const mapa = new Map<string, ProductoParaAlertas>(productos.map(p => [String(p.id), p as ProductoParaAlertas]))
    // Lo que cada combo vende hoy: las categorías resueltas (#1213).
    const resueltos = vigentes.map(c => ({ ...c, componentes: resolverLugares(c.componentes, productos) }))
    return alertasCombosParaReporte(
      resueltos,
      mapa,
      { margenMinimoPct: politicas.comboMargenMinimoPct, descuentoMaximoPct: politicas.comboDescuentoMaximoPct },
      verCostos,
    )
  }, [enabled, combos, productos, politicas.comboMargenMinimoPct, politicas.comboDescuentoMaximoPct, verCostos])
}
