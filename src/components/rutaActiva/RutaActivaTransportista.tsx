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
import React, { useState, useMemo, useEffect, useCallback, lazy, Suspense } from 'react';
import { Crosshair, WifiOff, Truck, Volume2, VolumeX, LocateFixed } from 'lucide-react';
import { formatPrecio } from '../../utils/formatters';
import { haversineMeters } from '../../utils/geo';
import { useAuthData } from '../../contexts/AuthDataContext';
import { useWatchPosition } from '../../hooks/useWatchPosition';
import { useDepositoCoords, useRecorridoActivoQuery } from '../../hooks/queries';
import { useNavegacionVoz } from '../../hooks/useNavegacionVoz';
import { useWakeLock } from '../../hooks/useWakeLock';
import { useGuiaNavegacion } from '../../hooks/useGuiaNavegacion';
import type { Coord } from '../../hooks/useNavTramo';
import { decodePolylines } from '../../utils/polyline';
import { useEntregaParada, type PedidoConCliente, type DatosPago, type DatosSalvedad } from './useEntregaParada';
import SheetParada, { type LinkRutaMaps } from './SheetParada';
import BannerManiobra from './BannerManiobra';
import ModalSalvedadItem from '../modals/ModalSalvedadItem';
import ModalRegistrarPago from '../modals/ModalRegistrarPago';
import type { PedidoDB, RegistrarSalvedadResult } from '../../types';

// Mapa con Google Maps JS (reemplaza el Leaflet; mejor reactividad y estética).
const MapaRuta = lazy(() => import('./MapaRutaGoogle'));

/** Radio del geofence de llegada, en metros */
const RADIO_LLEGADA_M = 100;
/** Accuracy máxima para confiar en el GPS (peor = IP-geoloc de desktop) */
const ACCURACY_MAX_M = 1000;
/** Más lejos que esto de la parada activa = el chofer no está en zona */
const DISTANCIA_ABSURDA_M = 50_000;

export interface RutaActivaTransportistaProps {
  onMarcarEntregado: (pedido: PedidoDB) => void;
  userId: string;
  onRegistrarSalvedad?: (data: DatosSalvedad) => Promise<RegistrarSalvedadResult>;
  onRegistrarPago?: (data: DatosPago) => Promise<unknown>;
  onEntregarSinCobrar?: (pedido: PedidoDB) => void | Promise<void>;
}

export default function RutaActivaTransportista({
  onMarcarEntregado,
  userId,
  onRegistrarSalvedad,
  onRegistrarPago,
  onEntregarSinCobrar,
}: RutaActivaTransportistaProps): React.ReactElement {
  const { isOnline } = useAuthData();
  const deposito = useDepositoCoords();
  // Guía giro-a-giro in-app: convive con el mapa y el sheet (no es overlay).
  const [guiando, setGuiando] = useState(false);
  const [vozOn, setVozOn] = useState(true);
  // Cámara de guía: se pausa cuando el chofer mueve el mapa a mano (estilo Maps);
  // el botón "centrar" la reactiva (+ bump del nonce para re-centrar).
  const [camaraSeguir, setCamaraSeguir] = useState(true);
  const [recenterNonce, setRecenterNonce] = useState(0);
  const voz = useNavegacionVoz();
  const wakeLock = useWakeLock();
  // Guiando: GPS más frecuente para seguir suave; si no, ahorro de batería.
  const { posicion } = useWatchPosition(true, guiando ? 1000 : 4000);
  // Ruta del día: el transportista lee del recorrido en_curso (las paradas que
  // armó el admin), NO de "todos sus pedidos asignados". Trae también la ruta
  // real (polylines) para dibujarla.
  const { data: recorridoActivo, isLoading: cargandoRuta } = useRecorridoActivoQuery(userId);
  const rutaReal = useMemo(
    () => decodePolylines(recorridoActivo?.polylines),
    [recorridoActivo?.polylines],
  );
  const [seguirPosicion, setSeguirPosicion] = useState(false);
  // Parada seleccionada manualmente (tap en mapa o en la lista). null = automática.
  const [paradaSeleccionadaId, setParadaSeleccionadaId] = useState<string | null>(null);

  const entrega = useEntregaParada({
    onMarcarEntregado,
    onRegistrarPago,
    onEntregarSinCobrar,
    onRegistrarSalvedad,
  });

  // Paradas de la ruta del día (ya vienen ordenadas y enriquecidas del recorrido)
  const pedidosOrdenados = useMemo<PedidoConCliente[]>(
    () => recorridoActivo?.paradas ?? [],
    [recorridoActivo?.paradas],
  );

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

  // GPS confiable: descarta la geolocalización por IP del navegador en
  // desktop (accuracy enorme) que producía el falso "808 km".
  const gpsConfiable = posicion != null && posicion.accuracy != null && posicion.accuracy <= ACCURACY_MAX_M;

  // Geofence: distancia a la parada activa. null si el GPS no es confiable o si
  // la distancia es absurda (chofer fuera de zona) → no mostrar dato falso.
  const distanciaMetros = useMemo((): number | null => {
    if (!gpsConfiable || !posicion || !paradaActiva?.cliente?.latitud || !paradaActiva?.cliente?.longitud) return null;
    const d = haversineMeters(
      { lat: posicion.lat, lng: posicion.lng },
      { lat: Number(paradaActiva.cliente.latitud), lng: Number(paradaActiva.cliente.longitud) },
    );
    return d > DISTANCIA_ABSURDA_M ? null : d;
  }, [gpsConfiable, posicion, paradaActiva]);
  const llegaste = gpsConfiable && distanciaMetros != null && distanciaMetros <= RADIO_LLEGADA_M;

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

  // --- Guía giro-a-giro in-app ---
  const destinoGuia = useMemo<Coord | null>(() => {
    if (paradaActiva?.cliente?.latitud != null && paradaActiva?.cliente?.longitud != null) {
      return { lat: Number(paradaActiva.cliente.latitud), lng: Number(paradaActiva.cliente.longitud) };
    }
    return null;
  }, [paradaActiva]);

  const guia = useGuiaNavegacion({
    destino: destinoGuia,
    posicion,
    gpsConfiable,
    llegaste,
    guiando,
    vozOn,
    voz,
  });

  // Desbloquear voz/haptics/wake-lock DENTRO del gesto (requisito del navegador).
  const iniciarGuia = useCallback((): void => {
    voz.prime();
    if (typeof navigator !== 'undefined' && 'vibrate' in navigator) {
      try { navigator.vibrate(1); } catch { /* sin haptics */ }
    }
    wakeLock.solicitar();
    setSeguirPosicion(true);
    setCamaraSeguir(true);
    setGuiando(true);
  }, [voz, wakeLock]);

  const pararGuia = useCallback((): void => {
    wakeLock.liberar();
    voz.callar();
    setGuiando(false);
  }, [wakeLock, voz]);

  // El chofer movió el mapa a mano → pausar el seguimiento de la cámara.
  const handleArrastreMapa = useCallback((): void => setCamaraSeguir(false), []);
  // Botón "centrar": volver a seguir y re-centrar en la posición/rumbo actuales.
  const recentrarMapa = useCallback((): void => {
    setCamaraSeguir(true);
    setRecenterNonce(n => n + 1);
  }, []);

  const toggleGuia = useCallback((): void => {
    if (guiando) pararGuia(); else iniciarGuia();
  }, [guiando, iniciarGuia, pararGuia]);

  // Si se completó la ruta (o no hay parada activa), parar la guía.
  useEffect(() => {
    if (guiando && !paradaActiva) pararGuia();
  }, [guiando, paradaActiva, pararGuia]);

  if (pedidosOrdenados.length === 0) {
    // Distinguir "todavía no hay ruta armada" de "ruta cargando".
    const sinRuta = !cargandoRuta && recorridoActivo == null;
    return (
      <div className="text-center py-12">
        <Truck className="w-16 h-16 mx-auto text-gray-300 dark:text-gray-600 mb-4" />
        <h3 className="text-xl font-semibold text-gray-600 dark:text-gray-400 mb-2">
          {cargandoRuta ? 'Cargando tu ruta…' : sinRuta ? 'Todavía no tenés ruta para hoy' : 'Ruta sin paradas'}
        </h3>
        <p className="text-gray-500 dark:text-gray-500">
          {cargandoRuta
            ? 'Un momento'
            : sinRuta
              ? 'El administrador todavía no armó tu ruta del día. Cuando la arme, va a aparecer acá.'
              : 'Tu ruta de hoy no tiene paradas cargadas.'}
        </p>
      </div>
    );
  }

  return (
    // Full-bleed: compensa el padding del <main> (px-4 pb-6) para que el mapa
    // ocupe todo el ancho y llegue hasta abajo de la pantalla.
    <div className="relative -mx-4 -mb-6 h-[calc(100dvh-5rem)] overflow-hidden">
      {/* El mapa ES la pantalla; la guía se monta encima (banner), no lo desmonta. */}
      <Suspense fallback={<div className="flex h-full items-center justify-center text-gray-400">Cargando mapa…</div>}>
        <MapaRuta
          paradas={paradasMapa}
          deposito={deposito}
          altura="full"
          // Al guiar se oculta la ruta del día completa para no confundir con el
          // tramo de navegación (rutaTramo); al parar vuelve la ruta completa.
          rutaReal={!guiando && rutaReal.length > 1 ? rutaReal : null}
          // Solo mostramos el punto azul con GPS confiable (no plantarlo en
          // medio del país con la geolocalización por IP del desktop).
          posicion={gpsConfiable && posicion ? { lat: posicion.lat, lng: posicion.lng, accuracy: posicion.accuracy, heading: posicion.heading, speed: posicion.speed } : null}
          paradaActivaOrden={paradaActiva?.orden_entrega ?? null}
          onParadaTap={handleParadaTapMapa}
          // Al guiar, el mapa sigue la posición y se acerca.
          seguirPosicion={(seguirPosicion || guiando) && gpsConfiable}
          zoomSeguir={guiando ? 17 : undefined}
          // Modo guía: con Vector Map ID activa la cámara heading-up (tilt+rumbo).
          modoGuia={guiando}
          // Tramo activo resaltado sobre la ruta del día (modo guía).
          rutaTramo={guiando && guia.rutaTramo.length > 1 ? guia.rutaTramo : null}
          // Pausa/recentrado de la cámara estilo Maps.
          camaraActiva={camaraSeguir}
          recenterNonce={recenterNonce}
          onArrastreUsuario={handleArrastreMapa}
        />
      </Suspense>

      {/* Overlay superior: al guiar muestra el banner de maniobra + toggle de
          voz; si no, el progreso del día + seguir-posición. El sheet (z-40)
          queda visible debajo en ambos casos (no hay overlay full-screen). */}
      <div className="pointer-events-none absolute inset-x-3 top-3 z-30 flex items-start justify-between gap-2">
        {guiando ? (
          <div className="pointer-events-auto min-w-0 flex-1">
            <BannerManiobra
              maniobra={llegaste ? 'LLEGADA' : (guia.pasoActual?.maniobra ?? null)}
              instruccion={llegaste ? 'Llegaste a destino' : (guia.pasoActual?.instruccion ?? null)}
              distanciaMetros={llegaste ? null : guia.distManiobra}
              maniobraSiguiente={llegaste ? null : (guia.pasoSiguiente?.maniobra ?? null)}
              instruccionSiguiente={llegaste ? null : (guia.pasoSiguiente?.instruccion ?? null)}
              cargando={guia.cargando}
              error={guia.error}
            />
          </div>
        ) : (
          <div className="pointer-events-auto rounded-2xl bg-white/95 px-4 py-2.5 shadow-lg backdrop-blur dark:bg-gray-800/95">
            <p className="text-sm font-bold text-gray-900 dark:text-white">
              {completadas}/{pedidosOrdenados.length} entregas
            </p>
            <p className="text-xs text-gray-500 dark:text-gray-400">
              {formatPrecio(porCobrar)} por cobrar
            </p>
          </div>
        )}
        {guiando ? (
          <button
            onClick={() => setVozOn(v => !v)}
            className={`pointer-events-auto flex h-11 w-11 flex-shrink-0 items-center justify-center rounded-full shadow-lg backdrop-blur transition-colors ${
              vozOn ? 'bg-blue-600 text-white' : 'bg-white/95 text-gray-600 dark:bg-gray-800/95 dark:text-gray-300'
            }`}
            aria-label={vozOn ? 'Silenciar voz' : 'Activar voz'}
          >
            {vozOn ? <Volume2 className="h-5 w-5" /> : <VolumeX className="h-5 w-5" />}
          </button>
        ) : (
          <button
            onClick={() => setSeguirPosicion(s => !s)}
            className={`pointer-events-auto flex h-11 w-11 flex-shrink-0 items-center justify-center rounded-full shadow-lg backdrop-blur transition-colors ${
              seguirPosicion ? 'bg-blue-600 text-white' : 'bg-white/95 text-gray-600 dark:bg-gray-800/95 dark:text-gray-300'
            }`}
            aria-label={seguirPosicion ? 'Dejar de seguir mi posición' : 'Seguir mi posición'}
          >
            <Crosshair className="h-5 w-5" />
          </button>
        )}
      </div>

      {/* Banner offline */}
      {!isOnline && (
        <div role="alert" className="absolute inset-x-3 top-20 z-20 flex items-center gap-2 rounded-xl bg-orange-500 px-3 py-2 text-white shadow-lg">
          <WifiOff className="h-4 w-4 flex-shrink-0" aria-hidden />
          <p className="text-sm font-medium">Sin conexión — las entregas no se están guardando</p>
        </div>
      )}

      {/* Botón "centrar" estilo Maps: aparece al guiar cuando el chofer movió el
          mapa a mano; lo vuelve a centrar y reactiva el seguimiento. */}
      {guiando && !camaraSeguir && (
        <button
          onClick={recentrarMapa}
          className="fixed right-4 bottom-[calc(7rem+env(safe-area-inset-bottom))] z-30 flex h-12 w-12 items-center justify-center rounded-full bg-white text-blue-600 shadow-lg ring-1 ring-black/10 active:bg-gray-100 dark:bg-gray-800 dark:text-blue-400"
          aria-label="Centrar el mapa en mi posición"
        >
          <LocateFixed className="h-6 w-6" />
        </button>
      )}

      {/* Bottom sheet con la parada activa */}
      <SheetParada
        paradas={pedidosOrdenados}
        paradaActiva={paradaActiva}
        distanciaMetros={distanciaMetros}
        llegaste={llegaste}
        onSeleccionarParada={(id) => { setParadaSeleccionadaId(id); setSeguirPosicion(false); }}
        onEntregar={(p) => { if (guiando) pararGuia(); entrega.marcarEntregado(p); }}
        onSalvedad={onRegistrarSalvedad ? entrega.abrirSalvedad : undefined}
        linksRutaMaps={linksRutaMaps}
        onToggleGuia={toggleGuia}
        guiando={guiando}
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
