/**
 * Type declarations for pdfExport.js
 */

import type { PedidoDB, PerfilDB, ClienteDB } from '../types/hooks';

export function generarOrdenPreparacion(pedidos: PedidoDB[]): Promise<void>;
export function generarHojaRuta(transportista: PerfilDB, pedidos: PedidoDB[]): Promise<void>;
export function generarHojaRutaOptimizada(transportista: PerfilDB, pedidos: PedidoDB[], distancia?: number, duracion?: number): Promise<void>;
export function generarReciboPago(pago: unknown, cliente: unknown): Promise<void>;
export function generarReciboPedido(pedido: PedidoDB, cliente: ClienteDB): Promise<void>;
