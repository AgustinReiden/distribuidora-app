/**
 * Type declarations for pdfExport.js
 */

import type { PedidoDB, PerfilDB, ClienteDB } from '../types/hooks';

/** Info opcional de ruta para el encabezado de la Hoja de Ruta (ver lib/pdf/hojaRutaOptimizada.js). */
export interface InfoRuta {
  fecha?: string | Date;
  distancia_formato?: string;
  duracion_formato?: string;
}

export function generarOrdenPreparacion(pedidos: PedidoDB[]): void;
export function generarHojaRutaOptimizada(transportista: PerfilDB, pedidos: PedidoDB[], infoRuta?: InfoRuta): void;
export function generarReciboPedido(pedido: PedidoDB, cliente: ClienteDB, options?: { formato?: 'a4' | 'comanda' }): void;
export function generarComandasMultiples(pedidos: PedidoDB[]): void;
