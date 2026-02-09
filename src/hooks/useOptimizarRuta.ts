import { useState, useCallback } from 'react';
import type { PedidoDB, ClienteDB } from '../types';

// ============================================================================
// TYPES
// ============================================================================

export interface DepositoCoords {
  lat: number;
  lng: number;
}

export interface PedidoParaOptimizar {
  pedido_id: string;
  cliente_id: string;
  cliente_nombre: string;
  direccion: string;
  latitud: number;
  longitud: number;
}

export interface OrdenOptimizadoItem {
  pedido_id: string;
  orden: number;
  cliente_nombre?: string;
  direccion?: string;
  latitud?: number;
  longitud?: number;
}

export interface RutaOptimizadaResponse {
  success?: boolean;
  total_pedidos: number;
  orden_optimizado?: OrdenOptimizadoItem[];
  distancia_total?: number;
  duracion_total?: number;
  polyline?: string;
  mensaje?: string;
  error?: string;
}

export interface OptimizarRutaRequestBody {
  transportista_id: string;
  deposito_lat: number;
  deposito_lng: number;
  pedidos: PedidoParaOptimizar[];
}

export interface UseOptimizarRutaReturn {
  loading: boolean;
  rutaOptimizada: RutaOptimizadaResponse | null;
  error: string | null;
  optimizarRuta: (transportistaId: string, pedidos?: PedidoDB[]) => Promise<RutaOptimizadaResponse | null>;
  limpiarRuta: () => void;
}

// ============================================================================
// CONSTANTS
// ============================================================================

// URL del webhook de n8n para optimizar rutas (desde variables de entorno)
const N8N_WEBHOOK_URL: string = import.meta.env.VITE_N8N_WEBHOOK_URL || '';

// NOTA: La Google API Key ahora debe estar configurada en el servidor n8n
// No se envia desde el cliente por razones de seguridad

// Coordenadas del depósito por defecto (se pueden configurar)
const DEPOSITO_DEFAULT: DepositoCoords = {
  lat: -26.8241,
  lng: -65.2226
};

// Clave para localStorage
const DEPOSITO_STORAGE_KEY = 'distribuidora_deposito_coords';

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

/**
 * Obtiene las coordenadas del depósito desde localStorage o usa las por defecto
 */
export const getDepositoCoords = (): DepositoCoords => {
  try {
    const stored = localStorage.getItem(DEPOSITO_STORAGE_KEY);
    if (stored) {
      const parsed = JSON.parse(stored) as Partial<DepositoCoords>;
      if (parsed.lat && parsed.lng) {
        return { lat: parsed.lat, lng: parsed.lng };
      }
    }
  } catch {
    // Error leyendo coordenadas, usar default
  }
  return DEPOSITO_DEFAULT;
};

/**
 * Guarda las coordenadas del depósito en localStorage
 */
export const setDepositoCoords = (lat: number, lng: number): boolean => {
  try {
    localStorage.setItem(DEPOSITO_STORAGE_KEY, JSON.stringify({ lat, lng }));
    return true;
  } catch {
    return false;
  }
};

// ============================================================================
// HOOK
// ============================================================================

/**
 * Hook para optimizar rutas de entrega usando Google Routes API vía n8n
 */
export function useOptimizarRuta(): UseOptimizarRutaReturn {
  const [loading, setLoading] = useState<boolean>(false);
  const [rutaOptimizada, setRutaOptimizada] = useState<RutaOptimizadaResponse | null>(null);
  const [error, setError] = useState<string | null>(null);

  /**
   * Optimiza la ruta de entregas para un transportista
   * @param transportistaId - UUID del transportista
   * @param pedidos - Array de pedidos con datos del cliente (incluyendo coordenadas)
   * @returns Datos de la ruta optimizada o null si hay error
   */
  const optimizarRuta = useCallback(async (
    transportistaId: string,
    pedidos: PedidoDB[] = []
  ): Promise<RutaOptimizadaResponse | null> => {
    if (!transportistaId) {
      setError('Debes seleccionar un transportista');
      return null;
    }

    if (!N8N_WEBHOOK_URL) {
      setError('La URL del servicio de optimización no está configurada. Configura VITE_N8N_WEBHOOK_URL en las variables de entorno.');
      return null;
    }

    // Filtrar pedidos del transportista que tengan coordenadas
    const pedidosConCoordenadas: PedidoParaOptimizar[] = pedidos
      .filter((p): p is PedidoDB & { cliente: ClienteDB & { latitud: number; longitud: number } } =>
        p.transportista_id === transportistaId &&
        p.estado === 'asignado' &&
        p.cliente?.latitud != null &&
        p.cliente?.longitud != null
      )
      .map(p => ({
        pedido_id: p.id,
        cliente_id: p.cliente_id,
        cliente_nombre: p.cliente?.nombre_fantasia || 'Sin nombre',
        direccion: p.cliente?.direccion || '',
        latitud: p.cliente.latitud,
        longitud: p.cliente.longitud
      }));

    if (pedidosConCoordenadas.length === 0) {
      const emptyResult: RutaOptimizadaResponse = {
        success: true,
        total_pedidos: 0,
        mensaje: 'No hay pedidos con coordenadas para optimizar'
      };
      setRutaOptimizada(emptyResult);
      return emptyResult;
    }

    setLoading(true);
    setError(null);

    // Obtener coordenadas del depósito (configurables)
    const deposito = getDepositoCoords();

    const requestBody: OptimizarRutaRequestBody = {
      transportista_id: transportistaId,
      deposito_lat: deposito.lat,
      deposito_lng: deposito.lng,
      pedidos: pedidosConCoordenadas
    };

    try {
      const response = await fetch(N8N_WEBHOOK_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(requestBody)
      });

      if (!response.ok) {
        // Intentar obtener más detalles del error
        let errorDetail = '';
        try {
          const errorText = await response.text();
          errorDetail = errorText ? ` - ${errorText}` : '';
        } catch {
          // No se pudo leer el cuerpo del error
        }
        throw new Error(`Error HTTP: ${response.status}${errorDetail}`);
      }

      // Parsear JSON
      let data: RutaOptimizadaResponse;
      try {
        const responseText = await response.text();
        data = JSON.parse(responseText) as RutaOptimizadaResponse;
      } catch {
        throw new Error('La respuesta no es JSON válido');
      }

      // Verificar si la respuesta indica error (del workflow n8n)
      if (data.error) {
        throw new Error(data.mensaje || data.error);
      }

      // Verificar si no hay pedidos
      if (data.total_pedidos === 0 || !data.orden_optimizado) {
        const noOrdersResult: RutaOptimizadaResponse = {
          success: true,
          total_pedidos: 0,
          mensaje: 'No hay pedidos asignados a este transportista'
        };
        setRutaOptimizada(noOrdersResult);
        return noOrdersResult;
      }

      // Respuesta exitosa con ruta optimizada
      setRutaOptimizada(data);
      return data;

    } catch (err) {
      const error = err as Error;
      // Determinar mensaje de error descriptivo
      let errorMessage = error.message || 'Error al optimizar la ruta';

      // Detectar errores específicos
      if (error.name === 'TypeError' && error.message === 'Failed to fetch') {
        errorMessage = 'Error de conexión: No se pudo conectar con el servidor. Verifica tu conexión a internet o intenta más tarde.';
      } else if (error.message.includes('CORS') || error.message.includes('cross-origin')) {
        errorMessage = 'Error de CORS: El servidor no permite esta solicitud desde el navegador.';
      }

      setError(errorMessage);
      return null;
    } finally {
      setLoading(false);
    }
  }, []);

  /**
   * Limpia los datos de la ruta optimizada
   */
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

/**
 * Configuración del depósito (exportada para uso en otros componentes)
 */
export const DEPOSITO_CONFIG: DepositoCoords = DEPOSITO_DEFAULT;

/**
 * URL del webhook (exportada para debug/configuración)
 */
export const WEBHOOK_URL: string = N8N_WEBHOOK_URL;
