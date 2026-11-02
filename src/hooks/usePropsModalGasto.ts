/**
 * Los props de `ModalGasto` que no dependen de dónde se abre: los arma la vista Gastos y también
 * el cierre de una rendición, que abre el mismo modal.
 */
import { useMemo } from 'react'
import {
  useRubrosGastoQuery,
  useVehiculosQuery,
  useSucursalesActivasQuery,
  useGuardarRubroGastoMutation,
} from './queries'
import { useAuthData } from '../contexts/AuthDataContext'
import { useSucursal } from '../contexts/SucursalContext'
import type { ModalGastoProps } from '../components/modals/ModalGasto'
import type { GrupoGasto, RubroGasto } from '../types/gastos'

type PropsComunesModalGasto = Pick<
  ModalGastoProps,
  | 'rubros' | 'vehiculos' | 'sucursalActual' | 'sucursalesUsuario' | 'sucursalesActivas'
  | 'esAdmin' | 'usuarioId' | 'onCrearRubro'
> & { tieneTodasLasSucursales: boolean; rubrosCargando: boolean }

export function usePropsModalGasto(): PropsComunesModalGasto {
  const { isAdmin, user } = useAuthData()
  const { sucursales, currentSucursalId, currentSucursalNombre } = useSucursal()
  const { data: rubros = [], isLoading: rubrosCargando = false } = useRubrosGastoQuery()
  const { data: vehiculos = [] } = useVehiculosQuery()
  const { data: sucursalesActivas = [] } = useSucursalesActivasQuery()
  const guardarRubro = useGuardarRubroGastoMutation()

  const sucursalActual = useMemo(
    () => ({ id: currentSucursalId ?? 0, nombre: currentSucursalNombre ?? '' }),
    [currentSucursalId, currentSucursalNombre],
  )
  const sucursalesUsuario = useMemo(
    () => sucursales.map(s => ({ id: s.id, nombre: s.nombre })),
    [sucursales],
  )
  // Quién puede tocar un compartido ajeno: el que tiene todas las sucursales activas.
  const tieneTodasLasSucursales =
    sucursalesActivas.length > 0 && sucursalesActivas.every(a => sucursalesUsuario.some(s => s.id === a.id))
  const rubrosActivos = useMemo(() => rubros.filter(r => r.activo), [rubros])

  const crearRubro = (nombre: string, grupo: GrupoGasto): Promise<RubroGasto> =>
    guardarRubro.mutateAsync({ nombre, grupo })

  return {
    rubros: rubrosActivos,
    rubrosCargando,
    vehiculos,
    sucursalActual,
    sucursalesUsuario,
    sucursalesActivas,
    esAdmin: isAdmin,
    usuarioId: user?.id,
    tieneTodasLasSucursales,
    onCrearRubro: isAdmin ? crearRubro : undefined,
  }
}
