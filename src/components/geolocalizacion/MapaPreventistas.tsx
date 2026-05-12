/* global google */
import React, { useEffect, useRef, useState } from 'react'
import { Loader2, MapPin } from 'lucide-react'
import { useGoogleMaps } from '../../hooks/useGoogleMaps'
import { colorPreventista, formatDistancia, clasificarDistancia, SEMAFORO_COLORS } from '../../utils/geo'
import { formatPrecio, formatHora } from '../../utils/formatters'
import type { PreventistaResumen, PedidoConGps, VisitaConGps } from '../../hooks/queries'

interface MapaPreventistasProps {
  preventistas: PreventistaResumen[]
  pedidos: PedidoConGps[]
  visitas: VisitaConGps[]
  preventistaSelectedId: string | null
  pedidoSelectedId: number | null
  onSelectPreventista: (id: string | null) => void
  onSelectPedido: (pedidoId: number | null) => void
}

// Tucumán fallback si no hay datos en el rango.
const FALLBACK_CENTER = { lat: -26.8083, lng: -65.2176 }
const FALLBACK_ZOOM = 12

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, ch => {
    switch (ch) {
      case '&': return '&amp;'
      case '<': return '&lt;'
      case '>': return '&gt;'
      case '"': return '&quot;'
      case "'": return '&#39;'
      default: return ch
    }
  })
}

function pinSymbol(color: string, scale = 8, opacity = 1): google.maps.Symbol {
  return {
    path: google.maps.SymbolPath.CIRCLE,
    fillColor: color,
    fillOpacity: opacity,
    strokeColor: '#ffffff',
    strokeWeight: 2,
    scale,
  }
}

export default function MapaPreventistas({
  preventistas,
  pedidos,
  visitas,
  preventistaSelectedId,
  pedidoSelectedId,
  onSelectPreventista,
  onSelectPedido,
}: MapaPreventistasProps): React.ReactElement {
  const { isLoaded, isLoading, error } = useGoogleMaps()
  const containerRef = useRef<HTMLDivElement | null>(null)
  const mapRef = useRef<google.maps.Map | null>(null)
  const markersRef = useRef<google.maps.Marker[]>([])
  const polylineRef = useRef<google.maps.Polyline | null>(null)
  const infoWindowRef = useRef<google.maps.InfoWindow | null>(null)
  const [mapReady, setMapReady] = useState(false)

  // Inicializar el mapa una sola vez.
  useEffect(() => {
    if (!isLoaded || !containerRef.current || mapRef.current) return
    const g = (window.google as unknown as { maps: typeof google.maps } | undefined)?.maps
    if (!g) return

    mapRef.current = new g.Map(containerRef.current, {
      center: FALLBACK_CENTER,
      zoom: FALLBACK_ZOOM,
      mapTypeControl: false,
      streetViewControl: false,
      fullscreenControl: true,
      clickableIcons: false,
    })
    infoWindowRef.current = new g.InfoWindow({ maxWidth: 280 })
    setMapReady(true)
  }, [isLoaded])

  // Re-render de markers + polyline cada vez que cambia la selección o data.
  useEffect(() => {
    if (!mapReady || !mapRef.current) return
    const g = (window.google as unknown as { maps: typeof google.maps } | undefined)?.maps
    if (!g) return
    const map = mapRef.current

    // Limpiar markers y polyline anteriores
    for (const m of markersRef.current) m.setMap(null)
    markersRef.current = []
    if (polylineRef.current) {
      polylineRef.current.setMap(null)
      polylineRef.current = null
    }
    infoWindowRef.current?.close()

    const bounds = new g.LatLngBounds()
    let pointCount = 0

    if (preventistaSelectedId) {
      // Vista de recorrido: pedidos del preventista (pins numerados + grandes)
      // + visitas del preventista (pins pequeños sin número) + clientes
      // referenciados en gris claro + polilínea cronológica que conecta
      // pedidos y visitas en una sola secuencia.
      const pedidosPropios = pedidos
        .filter(p => p.preventista_id === preventistaSelectedId)
      const visitasPropias = visitas
        .filter(v => v.preventista_id === preventistaSelectedId)

      const color = colorPreventista(preventistaSelectedId)

      // Markers de clientes (contexto): pequeños grises, sin duplicar si el
      // mismo cliente aparece en pedido y visita.
      const clientesDibujados = new Set<number>()
      const dibujarCliente = (id: number | null, lat: number | null, lng: number | null, nombre: string | null) => {
        if (id == null || lat == null || lng == null) return
        if (clientesDibujados.has(id)) return
        clientesDibujados.add(id)
        const marker = new g.Marker({
          position: { lat: Number(lat), lng: Number(lng) },
          map,
          title: nombre || 'Cliente',
          icon: pinSymbol('#cbd5e1', 5),
          zIndex: 1,
        })
        markersRef.current.push(marker)
        bounds.extend({ lat: Number(lat), lng: Number(lng) })
        pointCount++
      }
      for (const p of pedidosPropios) dibujarCliente(p.cliente_id, p.cliente_lat, p.cliente_lng, p.cliente_nombre)
      for (const v of visitasPropias) dibujarCliente(v.cliente_id, v.cliente_lat, v.cliente_lng, v.cliente_nombre)

      // Secuencia cronológica unificada para la polilínea y la numeración.
      type Evento =
        | { tipo: 'pedido'; ts: number; pedido: PedidoConGps }
        | { tipo: 'visita'; ts: number; visita: VisitaConGps }
      const eventos: Evento[] = []
      for (const p of pedidosPropios) {
        if (p.gps_status !== 'ok' || p.gps_lat == null || p.gps_lng == null) continue
        const ts = Date.parse(p.pedido_created_at ?? p.gps_capturado_at ?? '') || 0
        eventos.push({ tipo: 'pedido', ts, pedido: p })
      }
      for (const v of visitasPropias) {
        if (v.gps_status !== 'ok' || v.gps_lat == null || v.gps_lng == null) continue
        const ts = Date.parse(v.visita_created_at ?? v.gps_capturado_at ?? '') || 0
        eventos.push({ tipo: 'visita', ts, visita: v })
      }
      eventos.sort((a, b) => a.ts - b.ts)

      const path: google.maps.LatLngLiteral[] = []
      let pedidoIdx = 0
      let selectedAnchor: { marker: google.maps.Marker; pedido: PedidoConGps } | null = null

      for (const ev of eventos) {
        if (ev.tipo === 'pedido') {
          const p = ev.pedido
          const pos = { lat: Number(p.gps_lat!), lng: Number(p.gps_lng!) }
          const isSelected = pedidoSelectedId === p.pedido_id
          pedidoIdx++
          const marker = new g.Marker({
            position: pos,
            map,
            title: p.cliente_nombre || `Pedido #${p.pedido_id}`,
            label: { text: String(pedidoIdx), color: '#ffffff', fontWeight: '700', fontSize: '11px' },
            icon: pinSymbol(color, isSelected ? 14 : 11),
            zIndex: isSelected ? 1000 : 100 + pedidoIdx,
          })
          marker.addListener('click', () => {
            onSelectPedido(p.pedido_id)
            openPedidoInfoWindow(p, marker)
          })
          markersRef.current.push(marker)
          if (isSelected) selectedAnchor = { marker, pedido: p }
          path.push(pos)
          bounds.extend(pos)
          pointCount++
        } else {
          const v = ev.visita
          const pos = { lat: Number(v.gps_lat!), lng: Number(v.gps_lng!) }
          const marker = new g.Marker({
            position: pos,
            map,
            title: `Visita · ${v.cliente_nombre || 'Cliente'} · ${formatHora(v.visita_created_at)}`,
            icon: pinSymbol(color, 6, 0.75),
            zIndex: 50,
          })
          marker.addListener('click', () => {
            openVisitaInfoWindow(v, marker)
          })
          markersRef.current.push(marker)
          path.push(pos)
          bounds.extend(pos)
          pointCount++
        }
      }

      if (path.length >= 2) {
        polylineRef.current = new g.Polyline({
          path,
          map,
          geodesic: false,
          strokeColor: color,
          strokeOpacity: 0.7,
          strokeWeight: 3,
        })
      }

      if (selectedAnchor) {
        openPedidoInfoWindow(selectedAnchor.pedido, selectedAnchor.marker)
      }
    } else {
      // Vista global: 1 pin grande por preventista (última ubicación) + puntos
      // pequeños semi-transparentes para todas las visitas del rango. Esto
      // permite ver "dónde anduvieron" sin sobrecargar.
      for (const p of preventistas) {
        const ult = p.ultima_ubicacion
        if (!ult || ult.lat == null || ult.lng == null) continue
        const color = colorPreventista(p.preventista_id)
        const pos = { lat: Number(ult.lat), lng: Number(ult.lng) }
        const inicial = (p.preventista_nombre || '?').trim().charAt(0).toUpperCase()
        const marker = new g.Marker({
          position: pos,
          map,
          title: `${p.preventista_nombre} · ${formatHora(ult.capturado_at)} (${ult.tipo === 'visita' ? 'visita' : 'pedido'})`,
          label: { text: inicial, color: '#ffffff', fontWeight: '700', fontSize: '11px' },
          icon: pinSymbol(color, 13),
        })
        marker.addListener('click', () => {
          onSelectPreventista(p.preventista_id)
        })
        markersRef.current.push(marker)
        bounds.extend(pos)
        pointCount++
      }

      // Visitas globales como puntitos discretos (no clickeables, contexto).
      for (const v of visitas) {
        if (v.gps_status !== 'ok' || v.gps_lat == null || v.gps_lng == null) continue
        const pos = { lat: Number(v.gps_lat), lng: Number(v.gps_lng) }
        const color = colorPreventista(v.preventista_id)
        const marker = new g.Marker({
          position: pos,
          map,
          title: `Visita · ${v.cliente_nombre || 'Cliente'}`,
          icon: pinSymbol(color, 4, 0.45),
          zIndex: 10,
        })
        marker.addListener('click', () => onSelectPreventista(v.preventista_id))
        markersRef.current.push(marker)
        bounds.extend(pos)
        pointCount++
      }
    }

    // Encuadrar el mapa
    if (pointCount === 1) {
      // Un solo punto: centrar y mantener zoom moderado
      map.setCenter(bounds.getCenter())
      map.setZoom(15)
    } else if (pointCount > 1) {
      map.fitBounds(bounds, 60)
    } else {
      map.setCenter(FALLBACK_CENTER)
      map.setZoom(FALLBACK_ZOOM)
    }

    function openPedidoInfoWindow(p: PedidoConGps, anchor: google.maps.Marker) {
      if (!infoWindowRef.current || !mapRef.current) return
      const clasif = clasificarDistancia(p.distancia_m)
      const cfg = SEMAFORO_COLORS[clasif]
      const html = `
        <div style="font-family: ui-sans-serif, system-ui; padding: 4px 2px; max-width: 260px;">
          <div style="font-weight: 600; color: #111827; font-size: 13px;">${escapeHtml(p.cliente_nombre || 'Cliente sin nombre')}</div>
          <div style="color: #6b7280; font-size: 11px; margin-top: 2px;">
            Pedido #${p.pedido_id} · ${formatHora(p.pedido_created_at ?? p.gps_capturado_at)}
          </div>
          <div style="margin-top: 6px; font-size: 12px; color: #374151;">
            <strong>${formatPrecio(Number(p.total) || 0)}</strong>
            <span style="margin-left: 8px; padding: 1px 6px; border-radius: 9999px; font-size: 11px;"
                  class="${cfg.bg}">
              ${cfg.label} · ${escapeHtml(formatDistancia(p.distancia_m))}
            </span>
          </div>
        </div>
      `
      infoWindowRef.current.setContent(html)
      infoWindowRef.current.open(mapRef.current, anchor)
    }

    function openVisitaInfoWindow(v: VisitaConGps, anchor: google.maps.Marker) {
      if (!infoWindowRef.current || !mapRef.current) return
      const clasif = clasificarDistancia(v.distancia_m)
      const cfg = SEMAFORO_COLORS[clasif]
      const html = `
        <div style="font-family: ui-sans-serif, system-ui; padding: 4px 2px; max-width: 260px;">
          <div style="font-weight: 600; color: #111827; font-size: 13px;">${escapeHtml(v.cliente_nombre || 'Cliente sin nombre')}</div>
          <div style="color: #6b7280; font-size: 11px; margin-top: 2px;">
            Visita · ${formatHora(v.visita_created_at)}
          </div>
          <div style="margin-top: 6px; font-size: 12px;">
            <span style="padding: 1px 6px; border-radius: 9999px; font-size: 11px;"
                  class="${cfg.bg}">
              ${cfg.label} · ${escapeHtml(formatDistancia(v.distancia_m))}
            </span>
          </div>
        </div>
      `
      infoWindowRef.current.setContent(html)
      infoWindowRef.current.open(mapRef.current, anchor)
    }
  }, [mapReady, preventistas, pedidos, visitas, preventistaSelectedId, pedidoSelectedId, onSelectPedido, onSelectPreventista])

  // Cleanup
  useEffect(() => {
    return () => {
      for (const m of markersRef.current) m.setMap(null)
      markersRef.current = []
      if (polylineRef.current) polylineRef.current.setMap(null)
      infoWindowRef.current?.close()
    }
  }, [])

  if (error) {
    return (
      <div className="h-[60vh] bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-xl flex items-center justify-center text-sm text-red-600 dark:text-red-400 p-4 text-center">
        <div>
          <MapPin className="w-6 h-6 mx-auto mb-2" />
          No se pudo cargar el mapa. {error}
        </div>
      </div>
    )
  }

  return (
    <div className="relative h-[60vh] bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-xl overflow-hidden">
      <div ref={containerRef} className="absolute inset-0" />
      {(isLoading || !isLoaded) && (
        <div className="absolute inset-0 bg-white/70 dark:bg-gray-900/60 flex items-center justify-center text-sm text-gray-600 dark:text-gray-300">
          <Loader2 className="w-5 h-5 mr-2 animate-spin" />
          Cargando mapa…
        </div>
      )}
    </div>
  )
}
