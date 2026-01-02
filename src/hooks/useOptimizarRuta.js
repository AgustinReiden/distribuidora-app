import { useState, useCallback } from 'react';

// URL del webhook de n8n para optimizar rutas
const N8N_WEBHOOK_URL = 'https://n8n.shycia.com.ar/webhook/optimizar-ruta';

// Coordenadas del depósito (punto de origen/destino)
const DEPOSITO = {
  lat: -34.6037,
  lng: -58.3816
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
   * @returns {Object|null} Datos de la ruta optimizada o null si hay error
   */
  const optimizarRuta = useCallback(async (transportistaId) => {
    if (!transportistaId) {
      setError('Debes seleccionar un transportista');
      return null;
    }

    setLoading(true);
    setError(null);

    try {
      const response = await fetch(N8N_WEBHOOK_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          transportista_id: transportistaId,
          deposito_lat: DEPOSITO.lat,
          deposito_lng: DEPOSITO.lng
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
 */
export const DEPOSITO_CONFIG = DEPOSITO;

/**
 * URL del webhook (exportada para debug/configuración)
 */
export const WEBHOOK_URL = N8N_WEBHOOK_URL;
