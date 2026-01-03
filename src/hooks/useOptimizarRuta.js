import { useState, useCallback } from 'react';

// URL del webhook de n8n para optimizar rutas
const N8N_WEBHOOK_URL = 'https://n8n.shycia.com.ar/webhook/optimizar-ruta';

// Google API Key para Google Routes API
const GOOGLE_API_KEY = 'AIzaSyDm-wh1YAYmcOPHacSq2WYp1IB9oGfO_KQ';

// Coordenadas del depósito por defecto (se pueden configurar)
const DEPOSITO_DEFAULT = {
  lat: -26.8241,
  lng: -65.2226
};

// Clave para localStorage
const DEPOSITO_STORAGE_KEY = 'distribuidora_deposito_coords';

/**
 * Obtiene las coordenadas del depósito desde localStorage o usa las por defecto
 */
export const getDepositoCoords = () => {
  try {
    const stored = localStorage.getItem(DEPOSITO_STORAGE_KEY);
    if (stored) {
      const parsed = JSON.parse(stored);
      if (parsed.lat && parsed.lng) {
        return parsed;
      }
    }
  } catch (e) {
    console.error('Error leyendo coordenadas del depósito:', e);
  }
  return DEPOSITO_DEFAULT;
};

/**
 * Guarda las coordenadas del depósito en localStorage
 */
export const setDepositoCoords = (lat, lng) => {
  try {
    localStorage.setItem(DEPOSITO_STORAGE_KEY, JSON.stringify({ lat, lng }));
    return true;
  } catch (e) {
    console.error('Error guardando coordenadas del depósito:', e);
    return false;
  }
};

/**
 * Hook para optimizar rutas de entrega usando Google Routes API vía n8n
 *
 * El workflow de n8n:
 * 1. Recibe transportista_id y coordenadas del depósito
 * 2. Consulta los pedidos asignados al transportista
 * 3. Prepara los waypoints con las coordenadas de los clientes
 * 4. Llama a Google Routes API para optimizar el orden
 * 5. Retorna el orden optimizado de los pedidos
 *
 * @returns {Object} { loading, rutaOptimizada, error, optimizarRuta, limpiarRuta }
 */
export function useOptimizarRuta() {
  const [loading, setLoading] = useState(false);
  const [rutaOptimizada, setRutaOptimizada] = useState(null);
  const [error, setError] = useState(null);

  /**
   * Optimiza la ruta de entregas para un transportista
   * @param {string} transportistaId - UUID del transportista
   * @param {Array} pedidos - Array de pedidos con datos del cliente (incluyendo coordenadas)
   * @returns {Object|null} Datos de la ruta optimizada o null si hay error
   */
  const optimizarRuta = useCallback(async (transportistaId, pedidos = []) => {
    if (!transportistaId) {
      setError('Debes seleccionar un transportista');
      return null;
    }

    // Filtrar pedidos del transportista que tengan coordenadas
    const pedidosConCoordenadas = pedidos
      .filter(p =>
        p.transportista_id === transportistaId &&
        p.estado === 'asignado' &&
        p.cliente?.latitud &&
        p.cliente?.longitud
      )
      .map(p => ({
        pedido_id: p.id,
        cliente_id: p.cliente_id,
        cliente_nombre: p.cliente?.nombre_fantasia || p.cliente?.nombre || 'Sin nombre',
        direccion: p.cliente?.direccion || '',
        latitud: p.cliente.latitud,
        longitud: p.cliente.longitud
      }));

    if (pedidosConCoordenadas.length === 0) {
      setRutaOptimizada({
        success: true,
        total_pedidos: 0,
        mensaje: 'No hay pedidos con coordenadas para optimizar'
      });
      return { success: true, total_pedidos: 0 };
    }

    setLoading(true);
    setError(null);

    // Obtener coordenadas del depósito (configurables)
    const deposito = getDepositoCoords();

    try {
      const response = await fetch(N8N_WEBHOOK_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          transportista_id: transportistaId,
          deposito_lat: deposito.lat,
          deposito_lng: deposito.lng,
          google_api_key: GOOGLE_API_KEY,
          // Enviar los pedidos con coordenadas para que n8n no tenga que hacer el JOIN
          pedidos: pedidosConCoordenadas
        })
      });

      if (!response.ok) {
        throw new Error(`Error HTTP: ${response.status}`);
      }

      const data = await response.json();

      // Verificar si la respuesta indica error
      if (data.error) {
        throw new Error(data.error);
      }

      // Verificar si no hay pedidos
      if (data.total_pedidos === 0 || !data.orden_optimizado) {
        setRutaOptimizada({
          success: true,
          total_pedidos: 0,
          mensaje: 'No hay pedidos asignados a este transportista'
        });
        return { success: true, total_pedidos: 0 };
      }

      // Respuesta exitosa con ruta optimizada
      // Estructura esperada del workflow n8n:
      // {
      //   success: true,
      //   total_pedidos: number,
      //   orden_optimizado: [{ pedido_id, orden, cliente, direccion }],
      //   duracion_total: number (segundos),
      //   distancia_total: number (metros),
      //   duracion_formato: "X horas Y minutos"
      // }
      setRutaOptimizada(data);
      return data;

    } catch (err) {
      const errorMessage = err.message || 'Error al optimizar la ruta';
      setError(errorMessage);
      return null;
    } finally {
      setLoading(false);
    }
  }, []);

  /**
   * Limpia los datos de la ruta optimizada
   */
  const limpiarRuta = useCallback(() => {
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
 * Ahora es configurable, usar getDepositoCoords() y setDepositoCoords()
 */
export const DEPOSITO_CONFIG = DEPOSITO_DEFAULT;

/**
 * URL del webhook (exportada para debug/configuración)
 */
export const WEBHOOK_URL = N8N_WEBHOOK_URL;
