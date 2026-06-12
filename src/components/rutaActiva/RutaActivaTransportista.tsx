/**
 * RutaActivaTransportista — pantalla map-first (estilo Uber) del transportista.
 *
 * El mapa ES la pantalla: paradas numeradas, posición propia en vivo (GPS
 * local), parada activa destacada con flyTo. Abajo, un bottom sheet (vaul)
 * con la tarjeta de la parada activa y sus acciones; expandido muestra la
 * lista completa. Geofence: a <100m de la parada activa entra en modo
 * "Llegaste" y al entregar avanza sola a la siguiente.
 *
 * Reemplaza a VistaRutaTransportista (lista vertical) como vista del rol
 * transportista en /pedidos. La lógica de entrega/cobro/salvedad es la misma
 * (useEntregaParada). Diseño: docs/plans/2026-06-12-ruta-activa-design.md
 */
import React, { useState, useMemo, useEffect, lazy, Suspense } from 'react';
import { Crosshair, WifiOff, Truck } from 'lucide-react';
import { formatPrecio } from '../../utils/formatters';
import { haversineMeters } from '../../utils/geo';
import { useAuthData } from '../../contexts/AuthDataContext';
import { useWatchPosition } from '../../hooks/useWatchPosition';
import { getDepositoCoords } from '../../hooks/useOptimizarRuta';
import { useEntregaParada, type PedidoConCliente, type DatosPago, type DatosSalvedad } from './useEntregaParada';
import SheetParada, { type LinkRutaMaps } from './SheetParada';
import ModalSalvedadItem from '../modals/ModalSalvedadItem';
import ModalRegistrarPago from '../modals/ModalRegistrarPago';
import type { PedidoDB, ClienteDB, ProductoDB, RegistrarSalvedadResult } from '../../types';

const MapaRuta = lazy(() => import('../MapaRuta'));

/** Radio del geofence de llegada, en metros */
const RADIO_LLEGADA_M = 100;

export interface RutaActivaTransportistaProps {
  pedidos: PedidoDB[] | null;
  onMarcarEntregado: (pedido: PedidoDB) => void;
  userId: string;
  clientes: ClienteDB[];
  productos: ProductoDB[];
  onRegistrarSalvedad?: (data: DatosSalvedad) => Promise<RegistrarSalvedadResult>;
  onRegistrarPago?: (data: DatosPago) => Promise<unknown>;
  onEntregarSinCobrar?: (pedido: PedidoDB) => void | Promise<void>;
}

export default function RutaActivaTransportista({
  pedidos,
  onMarcarEntregado,
  userId,
  clientes,
  productos,
  onRegistrarSalvedad,
  onRegistrarPago,
  onEntregarSinCobrar,
}: RutaActivaTransportistaProps): React.ReactElement {
  const { isOnline } = useAuthData();
  const { posicion } = useWatchPosition(true);
  const [seguirPosicion, setSeguirPosicion] = useState(false);
  // Parada seleccionada manualmente (tap en mapa o en la lista). null = automática.
  const [paradaSeleccionadaId, setParadaSeleccionadaId] = useState<string | null>(null);

  const entrega = useEntregaParada({
    onMarcarEntregado,
    onRegistrarPago,
    onEntregarSinCobrar,
    onRegistrarSalvedad,
  });

  // Enriquecer pedidos con cliente y productos (mismo criterio que la vista anterior)
  const pedidosOrdenados = useMemo<PedidoConCliente[]>(() => {
    if (!pedidos) return [];
    return pedidos
      .filter(p => (p.estado === 'asignado' || p.estado === 'entregado') && p.transportista_id === userId)
      .map(pedido => {
        const cliente = (pedido.cliente_id && clientes.find(c => c.id === pedido.cliente_id))
          || (pedido.cliente?.nombre_fantasia ? pedido.cliente : undefined);
        const items = (pedido.items || []).map(item => ({
          ...item,
          producto: (item.producto_id && productos.find(pr => pr.id === item.producto_id))
            || item.producto || undefined,
        }));
        return { ...pedido, cliente, items } as PedidoConCliente;
      })
      .sort((a, b) => (a.orden_entrega || 999) - (b.orden_entrega || 999));
  }, [pedidos, clientes, productos, userId]);

  const pendientes = useMemo(
    () => pedidosOrdenados.filter(p => p.estado === 'asignado'),
    [pedidosOrdenados],
  );
  const completadas = pedidosOrdenados.length - pendientes.length;
  const porCobrar = pendientes
    .filter(p => p.estado_pago !== 'pagado')
    .reduce((sum, p) => sum + (p.total || 0), 0);

  // Parada activa: la seleccionada manualmente, o la primera pendiente
  const paradaActiva = useMemo<PedidoConCliente | null>(() => {
    if (paradaSeleccionadaId) {
      const sel = pedidosOrdenados.find(p => p.id === paradaSeleccionadaId);
      if (sel && sel.estado === 'asignado') return sel;
    }
    return pendientes[0] || null;
  }, [paradaSeleccionadaId, pedidosOrdenados, pendientes]);

  // Si la parada seleccionada se entregó (o desapareció), volver a la automática
  useEffect(() => {
    if (!paradaSeleccionadaId) return;
    const sel = pedidosOrdenados.find(p => p.id === paradaSeleccionadaId);
    if (!sel || sel.estado !== 'asignado') setParadaSeleccionadaId(null);
  }, [paradaSeleccionadaId, pedidosOrdenados]);

  // Geofence: distancia a la parada activa
  const distanciaMetros = useMemo((): number | null => {
    if (!posicion || !paradaActiva?.cliente?.latitud || !paradaActiva?.cliente?.longitud) return null;
    return haversineMeters(
      { lat: posicion.lat, lng: posicion.lng },
      { lat: Number(paradaActiva.cliente.latitud), lng: Number(paradaActiva.cliente.longitud) },
    );
  }, [posicion, paradaActiva]);
  const llegaste = distanciaMetros != null && distanciaMetros <= RADIO_LLEGADA_M;

  // Paradas para el mapa
  const paradasMapa = useMemo(
    () => pedidosOrdenados
      .filter(p => p.cliente?.latitud != null && p.cliente?.longitud != null)
      .map((p, i) => ({
        lat: Number(p.cliente!.latitud),
        lng: Number(p.cliente!.longitud),
        orden: p.orden_entrega || i + 1,
        titulo: p.cliente?.nombre_fantasia || 'Cliente',
        subtitulo: p.cliente?.direccion || undefined,
        entregado: p.estado === 'entregado',
      })),
    [pedidosOrdenados],
  );

  // Links a Google Maps por tramos (pendientes, desde la ubicación actual)
  const linksRutaMaps = useMemo((): LinkRutaMaps[] => {
    const coords = pendientes
      .filter(p => p.cliente?.latitud != null && p.cliente?.longitud != null)
      .map(p => `${p.cliente!.latitud},${p.cliente!.longitud}`);
    if (coords.length === 0) return [];
    const PARADAS_POR_LINK = 10; // 9 waypoints + destino
    const links: LinkRutaMaps[] = [];
    let origen: string | null = null;
    for (let i = 0; i < coords.length; i += PARADAS_POR_LINK) {
      const grupo = coords.slice(i, i + PARADAS_POR_LINK);
      const destino = grupo[grupo.length - 1];
      const waypoints = grupo.slice(0, -1).join('|');
      links.push({
        url: `https://www.google.com/maps/dir/?api=1${origen ? `&origin=${encodeURIComponent(origen)}` : ''}&destination=${encodeURIComponent(destino)}${waypoints ? `&waypoints=${encodeURIComponent(waypoints)}` : ''}&travelmode=driving`,
        desde: i + 1,
        hasta: i + grupo.length,
      });
      origen = destino;
    }
    return links;
  }, [pendientes]);

  const handleParadaTapMapa = (orden: number): void => {
    const p = pedidosOrdenados.find(x => x.orden_entrega === orden);
    if (p && p.estado === 'asignado') {
      setParadaSeleccionadaId(p.id);
      setSeguirPosicion(false);
    }
  };

  if (pedidosOrdenados.length === 0) {
    return (
      <div className="text-center py-12">
        <Truck className="w-16 h-16 mx-auto text-gray-300 dark:text-gray-600 mb-4" />
        <h3 className="text-xl font-semibold text-gray-600 dark:text-gray-400 mb-2">Sin entregas asignadas</h3>
        <p className="text-gray-500 dark:text-gray-500">No tienes entregas pendientes por el momento</p>
      </div>
    );
  }

  return (
    // Full-bleed: compensa el padding del <main> (px-4 pb-6) para que el mapa
    // ocupe todo el ancho y llegue hasta abajo de la pantalla.
    <div className="relative -mx-4 -mb-6 h-[calc(100dvh-5rem)] overflow-hidden">
      <Suspense fallback={<div className="flex h-full items-center justify-center text-gray-400">Cargando mapa…</div>}>
        <MapaRuta
          paradas={paradasMapa}
          deposito={getDepositoCoords()}
          altura="full"
          posicion={posicion ? { lat: posicion.lat, lng: posicion.lng, accuracy: posicion.accuracy } : null}
          paradaActivaOrden={paradaActiva?.orden_entrega ?? null}
          onParadaTap={handleParadaTapMapa}
          seguirPosicion={seguirPosicion}
        />
      </Suspense>

      {/* Header flotante: progreso del día */}
      <div className="pointer-events-none absolute inset-x-3 top-3 z-20 flex items-start justify-between gap-2">
        <div className="pointer-events-auto rounded-2xl bg-white/95 px-4 py-2.5 shadow-lg backdrop-blur dark:bg-gray-800/95">
          <p className="text-sm font-bold text-gray-900 dark:text-white">
            {completadas}/{pedidosOrdenados.length} entregas
          </p>
          <p className="text-xs text-gray-500 dark:text-gray-400">
            {formatPrecio(porCobrar)} por cobrar
          </p>
        </div>
        <button
          onClick={() => setSeguirPosicion(s => !s)}
          className={`pointer-events-auto flex h-11 w-11 items-center justify-center rounded-full shadow-lg backdrop-blur transition-colors ${
            seguirPosicion
              ? 'bg-blue-600 text-white'
              : 'bg-white/95 text-gray-600 dark:bg-gray-800/95 dark:text-gray-300'
          }`}
          aria-label={seguirPosicion ? 'Dejar de seguir mi posición' : 'Seguir mi posición'}
        >
          <Crosshair className="h-5 w-5" />
        </button>
      </div>

      {/* Banner offline */}
      {!isOnline && (
        <div role="alert" className="absolute inset-x-3 top-20 z-20 flex items-center gap-2 rounded-xl bg-orange-500 px-3 py-2 text-white shadow-lg">
          <WifiOff className="h-4 w-4 flex-shrink-0" aria-hidden />
          <p className="text-sm font-medium">Sin conexión — las entregas no se están guardando</p>
        </div>
      )}

      {/* Bottom sheet con la parada activa */}
      <SheetParada
        paradas={pedidosOrdenados}
        paradaActiva={paradaActiva}
        distanciaMetros={distanciaMetros}
        llegaste={llegaste}
        onSeleccionarParada={(id) => { setParadaSeleccionadaId(id); setSeguirPosicion(false); }}
        onEntregar={entrega.marcarEntregado}
        onSalvedad={onRegistrarSalvedad ? entrega.abrirSalvedad : undefined}
        linksRutaMaps={linksRutaMaps}
      />

      {/* Modales del flujo de entrega (mismos que la vista anterior) */}
      {entrega.salvedadModal && (
        <ModalSalvedadItem
          pedidoId={entrega.salvedadModal.pedidoId}
          item={entrega.salvedadModal.item}
          onSave={entrega.guardarSalvedad}
          onClose={entrega.cerrarSalvedad}
        />
      )}
      {entrega.pedidoParaCobrar && entrega.pedidoParaCobrar.cliente && (
        <ModalRegistrarPago
          cliente={entrega.pedidoParaCobrar.cliente}
          saldoPendiente={(entrega.pedidoParaCobrar.total || 0) - (entrega.pedidoParaCobrar.monto_pagado || 0)}
          pedidos={[entrega.pedidoParaCobrar as unknown as import('../../types').Pedido]}
          onClose={entrega.cerrarModalPago}
          onConfirmar={entrega.confirmarPago}
          onEntregarSinCobrar={onEntregarSinCobrar ? entrega.entregarSinCobrar : undefined}
        />
      )}
    </div>
  );
}
