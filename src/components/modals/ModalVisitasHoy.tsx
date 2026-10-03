/**
 * Modal "Visitas del día".
 *
 * Lista cronológica de las visitas que el preventista marcó hoy. Pensado
 * para que pueda ver de un vistazo a qué clientes ya pasó y cuáles le
 * faltan, sin tener que abrir el panel admin (que no ve).
 *
 * Datos vienen del RPC `listar_visitas_hoy` (scope al preventista logueado
 * + sucursal activa). La lista es `ListaVisitasHoy`, la misma que muestra la
 * pantalla "Hoy" del preventista.
 */
import React from 'react'
import ModalBase from './ModalBase'
import { useVisitasHoyQuery } from '../../hooks/queries'
import ListaVisitasHoy from '../visitas/ListaVisitasHoy'

interface ModalVisitasHoyProps {
  userId: string | null
  onClose: () => void
}

export default function ModalVisitasHoy({ userId, onClose }: ModalVisitasHoyProps): React.ReactElement {
  const { data: visitas = [], isLoading, error } = useVisitasHoyQuery(userId, { enabled: !!userId })

  return (
    <ModalBase title="Visitas del día" onClose={onClose} maxWidth="max-w-lg">
      <ListaVisitasHoy visitas={visitas} cargando={isLoading} error={error} />
    </ModalBase>
  )
}
