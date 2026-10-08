/**
 * Type declarations for pdfExport.js
 */

import type { PedidoDB, PerfilDB, ClienteDB } from '../types/hooks';
import type { RolUsuario } from '../types';

/** Info opcional de ruta para el encabezado de la Hoja de Ruta (ver lib/pdf/hojaRutaOptimizada.ts). */
export interface InfoRuta {
  fecha?: string | Date;
  distancia_formato?: string;
  duracion_formato?: string;
}

export function generarOrdenPreparacion(pedidos: PedidoDB[]): void;
export function generarHojaRutaOptimizada(transportista: PerfilDB, pedidos: PedidoDB[], infoRuta?: InfoRuta): void;
export interface OpcionesManifiesto {
  nombresSubrubro?: Record<string, string> | Map<string, string>;
  productos?: Array<{ id?: string | number; categoria?: string | null; subcategoria_id?: string | null }>;
}
export function generarManifiestoCarga(transportista: PerfilDB, pedidos: PedidoDB[], infoRuta?: InfoRuta, opciones?: OpcionesManifiesto): void;
export function generarHojaRutaYManifiesto(transportista: PerfilDB, pedidos: PedidoDB[], infoRuta?: InfoRuta, opciones?: OpcionesManifiesto): void;
export function generarReciboPedido(pedido: PedidoDB, cliente: ClienteDB, options?: { formato?: 'a4' | 'comanda'; rol?: RolUsuario | null }): void;
export function generarComandasMultiples(pedidos: PedidoDB[], options?: { rol?: RolUsuario | null }): void;
