import { useState, useCallback } from 'react';

// URL del webhook de n8n para optimizar rutas (desde variables de entorno)
const N8N_WEBHOOK_URL = import.meta.env.VITE_N8N_WEBHOOK_URL || '';

// NOTA: La Google API Key ahora debe estar configurada en el servidor n8n
// No se envia desde el cliente por razones de seguridad

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
  } catch {
    // Error leyendo coordenadas, usar default
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
  } catch {
    return false;
  }
};

/**
 * Hook para optimizar rutas de entrega usando Google Routes API vía n8n
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

    const requestBody = {
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
      let data;
      try {
        const responseText = await response.text();
        data = JSON.parse(responseText);
      } catch {
        throw new Error('La respuesta no es JSON válido');
      }

      // Verificar si la respuesta indica error (del workflow n8n)
      if (data.error) {
        throw new Error(data.mensaje || data.error);
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
      setRutaOptimizada(data);
      return data;

    } catch (err) {
      // Determinar mensaje de error descriptivo
      let errorMessage = err.message || 'Error al optimizar la ruta';

      // Detectar errores específicos
      if (err.name === 'TypeError' && err.message === 'Failed to fetch') {
        errorMessage = 'Error de conexión: No se pudo conectar con el servidor. Verifica tu conexión a internet o intenta más tarde.';
      } else if (err.message.includes('CORS') || err.message.includes('cross-origin')) {
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
export const DEPOSITO_CONFIG = DEPOSITO_DEFAULT;

/**
 * URL del webhook (exportada para debug/configuración)
 */
export const WEBHOOK_URL = N8N_WEBHOOK_URL;
