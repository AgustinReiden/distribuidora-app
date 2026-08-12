/**
 * Motivos tipificados de no entrega y de cancelación (mig 143).
 *
 * Antes esto era un textarea libre. Los 218 cancelados históricos tenían
 * "CERRADO", "SIN PLATA", "NO TENIA PLATA", "Prueba", "UNIFICAMOS PEDIDO" y
 * decenas de variantes más, así que no se podía medir nada ni mostrarle al
 * preventista un motivo confiable.
 *
 * Los valores deben coincidir con los CHECK de la migración 140.
 */

/** Motivos que puede elegir el chofer cuando no pudo entregar. */
export const MOTIVOS_NO_ENTREGA = [
  { valor: 'cerrado', label: 'Estaba cerrado', descripcion: 'El local no estaba abierto' },
  { valor: 'sin_dinero', label: 'No tenía dinero', descripcion: 'El cliente no pudo pagar' },
  { valor: 'cliente_rechaza', label: 'Lo rechazó', descripcion: 'El cliente no quiso recibirlo' },
  { valor: 'ausente', label: 'No había nadie', descripcion: 'Nadie atendió' },
  { valor: 'direccion_incorrecta', label: 'Dirección incorrecta', descripcion: 'No se encontró el domicilio' },
  { valor: 'clima', label: 'Por el clima', descripcion: 'No se pudo llegar' },
  { valor: 'otro', label: 'Otro', descripcion: 'Contá qué pasó' },
] as const;

export type MotivoNoEntrega = (typeof MOTIVOS_NO_ENTREGA)[number]['valor'];

/** Motivos administrativos, además de los de arriba, al cancelar un pedido. */
export const MOTIVOS_CANCELACION_ADMIN = [
  { valor: 'cliente_cancelo', label: 'El cliente lo canceló' },
  { valor: 'error_de_carga', label: 'Error de carga' },
  { valor: 'duplicado', label: 'Pedido duplicado' },
  { valor: 'unifica_pedidos', label: 'Se unificó con otro pedido' },
  { valor: 'prueba', label: 'Pedido de prueba' },
] as const;

/**
 * Motivos que estampa el sistema y nadie elige a mano. No van en el
 * desplegable, pero necesitan etiqueta para los listados y el reporte: sin
 * esto, cada cambio de cliente quedaba como cancelación sin clasificar y le
 * hacía un agujero a la medición (mig 175).
 */
export const MOTIVOS_CANCELACION_SISTEMA = [
  { valor: 'cambio_de_cliente', label: 'Cambio de cliente' },
] as const;

/** Etiqueta legible de cualquier motivo, para mostrar en listados y reportes. */
export const LABEL_MOTIVO: Record<string, string> = {
  ...Object.fromEntries(MOTIVOS_NO_ENTREGA.map(m => [m.valor, m.label])),
  ...Object.fromEntries(MOTIVOS_CANCELACION_ADMIN.map(m => [m.valor, m.label])),
  ...Object.fromEntries(MOTIVOS_CANCELACION_SISTEMA.map(m => [m.valor, m.label])),
};

/** Texto para el preventista, en tercera persona. */
export const MOTIVO_EXPLICACION: Record<string, string> = {
  cerrado: 'El local estaba cerrado',
  sin_dinero: 'El cliente no tenía dinero',
  cliente_rechaza: 'El cliente rechazó el pedido',
  ausente: 'No había nadie en el local',
  direccion_incorrecta: 'La dirección es incorrecta',
  clima: 'No se pudo llegar por el clima',
  otro: 'Otro motivo',
};
