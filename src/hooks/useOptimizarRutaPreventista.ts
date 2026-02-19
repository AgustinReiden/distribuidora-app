import { useState, useCallback } from 'react';
import type { ClienteDB } from '../types';
import { getDepositoCoords } from './useOptimizarRuta';

// ============================================================================
// TYPES
// ============================================================================

export interface ClienteParaOptimizar {
  pedido_id: string; // Mapped from cliente_id for n8n compatibility
  cliente_id: string;
  cliente_nombre: string;
  direccion: string;
  latitud: number;
  longitud: number;
}

export interface OrdenOptimizadoClienteItem {
  cliente_id: string;
  orden: number;
  cliente_nombre?: string;
  direccion?: string;
  latitud?: number;
  longitud?: number;
}

export interface RutaPreventistaResponse {
  success?: boolean;
  total_clientes: number;
  orden_optimizado?: OrdenOptimizadoClienteItem[];
  distancia_total?: number;
  duracion_total?: number;
  distancia_formato?: string;
  duracion_formato?: string;
  polyline?: string;
  mensaje?: string;
  error?: string;
}

export interface UseOptimizarRutaPreventistaReturn {
  loading: boolean;
  rutaOptimizada: RutaPreventistaResponse | null;
  error: string | null;
  optimizarRuta: (preventistaId: string, clientes: ClienteDB[]) => Promise<RutaPreventistaResponse | null>;
  limpiarRuta: () => void;
}

// ============================================================================
// CONSTANTS
// ============================================================================

const N8N_WEBHOOK_URL: string = import.meta.env.VITE_N8N_WEBHOOK_URL || '';
const GOOGLE_API_KEY: string = import.meta.env.VITE_GOOGLE_API_KEY || '';

// ============================================================================
// HOOK
// ============================================================================

export function useOptimizarRutaPreventista(): UseOptimizarRutaPreventistaReturn {
  const [loading, setLoading] = useState<boolean>(false);
  const [rutaOptimizada, setRutaOptimizada] = useState<RutaPreventistaResponse | null>(null);
  const [error, setError] = useState<string | null>(null);

  const optimizarRuta = useCallback(async (
    preventistaId: string,
    clientes: ClienteDB[]
  ): Promise<RutaPreventistaResponse | null> => {
    if (!preventistaId) {
      setError('Debes seleccionar un preventista');
      return null;
    }

    if (!N8N_WEBHOOK_URL) {
      setError('La URL del servicio de optimización no está configurada. Configura VITE_N8N_WEBHOOK_URL en las variables de entorno.');
      return null;
    }

    // Filter clients with coordinates
    const clientesConCoords: ClienteParaOptimizar[] = clientes
      .filter((c): c is ClienteDB & { latitud: number; longitud: number } =>
        c.latitud != null && c.longitud != null
      )
      .map(c => ({
        pedido_id: c.id,       // n8n expects pedido_id
        cliente_id: c.id,
        cliente_nombre: c.nombre_fantasia || 'Sin nombre',
        direccion: c.direccion || '',
        latitud: c.latitud,
        longitud: c.longitud
      }));

    if (clientesConCoords.length === 0) {
      const emptyResult: RutaPreventistaResponse = {
        success: true,
        total_clientes: 0,
        mensaje: 'No hay clientes con coordenadas para optimizar'
      };
      setRutaOptimizada(emptyResult);
      return emptyResult;
    }

    setLoading(true);
    setError(null);

    const deposito = getDepositoCoords();

    try {
      const response = await fetch(N8N_WEBHOOK_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          transportista_id: preventistaId,  // reuse field for n8n
          deposito_lat: deposito.lat,
          deposito_lng: deposito.lng,
          pedidos: clientesConCoords,         // reuse field for n8n
          google_api_key: GOOGLE_API_KEY
        })
      });

      if (!response.ok) {
        let errorDetail = '';
        try {
          const errorText = await response.text();
          errorDetail = errorText ? ` - ${errorText}` : '';
        } catch {
          // ignore
        }
        throw new Error(`Error HTTP: ${response.status}${errorDetail}`);
      }

      let data: Record<string, unknown>;
      try {
        const responseText = await response.text();
        data = JSON.parse(responseText);
      } catch {
        throw new Error('La respuesta no es JSON válido');
      }

      if (data.error) {
        throw new Error((data.mensaje as string) || (data.error as string));
      }

      // Map response: pedido_id -> cliente_id
      const ordenOptimizado = (data.orden_optimizado as Array<Record<string, unknown>> || []).map(item => ({
        cliente_id: String(item.pedido_id || item.cliente_id),
        orden: Number(item.orden),
        cliente_nombre: item.cliente as string || item.cliente_nombre as string,
        direccion: item.direccion as string,
        latitud: item.latitud as number | undefined,
        longitud: item.longitud as number | undefined
      }));

      const result: RutaPreventistaResponse = {
        success: true,
        total_clientes: Number(data.total_pedidos || ordenOptimizado.length),
        orden_optimizado: ordenOptimizado,
        distancia_total: data.distancia_total as number | undefined,
        duracion_total: data.duracion_total as number | undefined,
        distancia_formato: data.distancia_formato as string | undefined,
        duracion_formato: data.duracion_formato as string | undefined,
        polyline: data.polyline as string | undefined
      };

      setRutaOptimizada(result);
      return result;

    } catch (err) {
      const e = err as Error;
      let errorMessage = e.message || 'Error al optimizar la ruta';

      if (e.name === 'TypeError' && e.message === 'Failed to fetch') {
        errorMessage = 'Error de conexión: No se pudo conectar con el servidor.';
      }

      setError(errorMessage);
      return null;
    } finally {
      setLoading(false);
    }
  }, []);

  const limpiarRuta = useCallback((): void => {
    setRutaOptimizada(null);
    setError(null);
  }, []);

  return {
    loading,
    rutaOptimizada,
    error,
    optimizarRuta,
    limpiarRuta
  };
}
