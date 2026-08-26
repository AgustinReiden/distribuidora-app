import { useState, useCallback } from 'react';
import type { ClienteDB } from '../types';
import { getDepositoCoords } from './useOptimizarRuta';
import { supabase } from '../lib/supabase';

// ============================================================================
// TYPES
// ============================================================================

export interface ClienteParaOptimizar {
  /** La edge function llama `pedido_id` a la clave de cada parada. */
  pedido_id: string;
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

    // Filter clients with coordinates
    const clientesConCoords: ClienteParaOptimizar[] = clientes
      .filter((c): c is ClienteDB & { latitud: number; longitud: number } =>
        c.latitud != null && c.longitud != null
      )
      .map(c => ({
        pedido_id: c.id,       // la edge llama pedido_id a la clave de la parada
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
      // Misma Edge Function que usa la ruta de reparto. Antes esto iba a un
      // webhook de n8n con la API key de Google en el body; la edge la tiene
      // como secret del servidor y exige JWT.
      const { data: fnData, error: fnError } = await supabase.functions.invoke(
        'optimizar-ruta',
        {
          body: {
            transportista_id: preventistaId,
            deposito_lat: deposito.lat,
            deposito_lng: deposito.lng,
            // La edge llama `pedidos` a sus paradas; acá son clientes a visitar.
            pedidos: clientesConCoords,
          },
        }
      );

      if (fnError) {
        throw new Error(fnError.message || 'No se pudo contactar el servicio de optimización');
      }

      const data = (fnData ?? {}) as Record<string, unknown>;

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
        // La edge devuelve `polylines` (un tramo por leg); la UI no lo usa hoy.
        polyline: (data.polylines as string[] | undefined)?.[0]
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
