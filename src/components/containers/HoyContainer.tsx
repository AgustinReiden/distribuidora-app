/**
 * HoyContainer (WP-48, #773): datos y acciones de la pantalla "Hoy" del
 * preventista. La vista (`VistaHoy`) es presentacional.
 *
 *  - Visitas de hoy: `useVisitasHoyQuery`, la misma query que el modal
 *    "Visitas del día" de /pedidos. Marcar una visita la invalida
 *    (`useRegistrarVisitaMutation`), así que la lista se actualiza sola.
 *  - Objetivos del mes: `useAvanceMetasQuery` con los mismos argumentos que
 *    DashboardContainer (sin id: el RPC devuelve los del usuario logueado;
 *    siempre el mes corriente).
 *  - "Marcar visita": el `ModalMarcarVisita` de siempre, con las mismas props
 *    que le pasa PedidosContainer.
 *  - "Nuevo pedido": navega a /pedidos con `state: { abrir: 'nuevoPedido' }`.
 *    PedidosContainer lo lee UNA vez, abre el alta y limpia el state. Si se
 *    cambia la forma del state acá, se cambia allá (y en
 *    PedidosContainer.abrirDesdeHoy.test.tsx, que monta las dos pantallas).
 */
import React, { Suspense, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Loader2 } from 'lucide-react'
import { useAvanceMetasQuery, useClientesQuery, useVisitasHoyQuery, periodoMensual } from '../../hooks/queries'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useResetOnSucursalChange } from '../../hooks/useResetOnSucursalChange'
import { lazyWithReload } from '../../utils/lazyWithReload'

const VistaHoy = lazyWithReload(() => import('../vistas/VistaHoy'))
const ModalMarcarVisita = lazyWithReload(() => import('../modals/ModalMarcarVisita'))

function LoadingState() {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

export default function HoyContainer(): React.ReactElement {
  const { user, isAdmin, isPreventista, authReady } = useAuthData()
  const navigate = useNavigate()
  const userId = user?.id ?? null
  const [marcarVisitaAbierto, setMarcarVisitaAbierto] = useState(false)

  const { data: visitas = [], isLoading: cargandoVisitas, error: errorVisitas } =
    useVisitasHoyQuery(userId, { enabled: !!userId })

  const { data: avanceMetas } = useAvanceMetasQuery(
    undefined,
    periodoMensual(),
    authReady && (isPreventista || isAdmin),
  )

  // Para el modal de visita (filtra activos y asignación adentro).
  const { data: clientes = [] } = useClientesQuery()

  // Como en PedidosContainer: el modal no queda abierto con los clientes de la
  // sucursal anterior.
  useResetOnSucursalChange(() => setMarcarVisitaAbierto(false))

  return (
    <>
      <Suspense fallback={<LoadingState />}>
        <VistaHoy
          fecha={new Date()}
          visitas={visitas}
          cargandoVisitas={cargandoVisitas}
          errorVisitas={errorVisitas}
          avanceMetas={avanceMetas}
          onNuevoPedido={() => navigate('/pedidos', { state: { abrir: 'nuevoPedido' } })}
          onMarcarVisita={() => setMarcarVisitaAbierto(true)}
        />
      </Suspense>

      {marcarVisitaAbierto && (
        <Suspense fallback={null}>
          <ModalMarcarVisita
            clientes={clientes}
            userId={userId}
            isAdmin={isAdmin}
            isPreventista={isPreventista}
            onClose={() => setMarcarVisitaAbierto(false)}
          />
        </Suspense>
      )}
    </>
  )
}
