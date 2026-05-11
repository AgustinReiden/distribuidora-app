/* global google */
import React, { useEffect, useRef, useState } from 'react'
import { Loader2, MapPin } from 'lucide-react'
import { useGoogleMaps } from '../../hooks/useGoogleMaps'
import { colorPreventista, formatDistancia, clasificarDistancia, SEMAFORO_COLORS } from '../../utils/geo'
import { formatPrecio } from '../../utils/formatters'
import type { PreventistaResumen, PedidoConGps } from '../../hooks/queries'

interface MapaPreventistasProps {
  preventistas: PreventistaResumen[]
  pedidos: PedidoConGps[]
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

function formatHora(iso: string | null | undefined): string {
  if (!iso) return '—'
  try {
    return new Date(iso).toLocaleTimeString('es-AR', { hour: '2-digit', minute: '2-digit' })
  } catch {
    return '—'
  }
}

function pinSymbol(color: string, scale = 8): google.maps.Symbol {
  return {
    path: google.maps.SymbolPath.CIRCLE,
    fillColor: color,
    fillOpacity: 1,
    strokeColor: '#ffffff',
    strokeWeight: 2,
    scale,
  }
}

export default function MapaPreventistas({
  preventistas,
  pedidos,
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
      // Vista de recorrido: pins por pedido del preventista seleccionado +
      // markers gris claro para los clientes (contexto) + polilínea conectando
      // por hora.
      const propios = pedidos
        .filter(p => p.preventista_id === preventistaSelectedId)
        .sort((a, b) => {
          const ta = a.gps_capturado_at ? Date.parse(a.gps_capturado_at) : 0
          const tb = b.gps_capturado_at ? Date.parse(b.gps_capturado_at) : 0
          return ta - tb
        })

      const color = colorPreventista(preventistaSelectedId)
      const path: google.maps.LatLngLiteral[] = []

      // Markers de clientes (contexto): pequeños grises
      for (const p of propios) {
        if (p.cliente_lat != null && p.cliente_lng != null) {
          const marker = new g.Marker({
            position: { lat: Number(p.cliente_lat), lng: Number(p.cliente_lng) },
            map,
            title: p.cliente_nombre || 'Cliente',
            icon: pinSymbol('#cbd5e1', 5),
            zIndex: 1,
          })
          markersRef.current.push(marker)
          bounds.extend({ lat: Number(p.cliente_lat), lng: Number(p.cliente_lng) })
          pointCount++
        }
      }

      // Markers de check-ins (numerados)
      propios
        .filter(p => p.gps_status === 'ok' && p.gps_lat != null && p.gps_lng != null)
        .forEach((p, idx) => {
          const pos = { lat: Number(p.gps_lat!), lng: Number(p.gps_lng!) }
          const isSelected = pedidoSelectedId === p.pedido_id
          const marker = new g.Marker({
            position: pos,
            map,
            title: p.cliente_nombre || `Pedido #${p.pedido_id}`,
            label: { text: String(idx + 1), color: '#ffffff', fontWeight: '700', fontSize: '11px' },
            icon: pinSymbol(color, isSelected ? 14 : 11),
            zIndex: isSelected ? 1000 : 100 + idx,
          })
          marker.addListener('click', () => {
            onSelectPedido(p.pedido_id)
            openPedidoInfoWindow(p, marker)
          })
          markersRef.current.push(marker)
          path.push(pos)
          bounds.extend(pos)
          pointCount++
        })

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

      // Si hay un pedido seleccionado, abrir su info window al final.
      if (pedidoSelectedId != null) {
        const idx = propios.findIndex(p => p.pedido_id === pedidoSelectedId && p.gps_status === 'ok')
        if (idx >= 0) {
          const clienteMarkersOffset = propios.filter(p => p.cliente_lat != null && p.cliente_lng != null).length
          const target = markersRef.current[clienteMarkersOffset + idx]
          if (target) openPedidoInfoWindow(propios[idx], target)
        }
      }
    } else {
      // Vista global: 1 pin por preventista (su última ubicación).
      for (const p of preventistas) {
        const ult = p.ultima_ubicacion
        if (!ult || ult.lat == null || ult.lng == null) continue
        const color = colorPreventista(p.preventista_id)
        const pos = { lat: Number(ult.lat), lng: Number(ult.lng) }
        const inicial = (p.preventista_nombre || '?').trim().charAt(0).toUpperCase()
        const marker = new g.Marker({
          position: pos,
          map,
          title: `${p.preventista_nombre} · ${formatHora(ult.capturado_at)}`,
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
            Pedido #${p.pedido_id} · ${formatHora(p.gps_capturado_at)}
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
  }, [mapReady, preventistas, pedidos, preventistaSelectedId, pedidoSelectedId, onSelectPedido, onSelectPreventista])

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
