/**
 * Paleta en uso, con las clases Tailwind ESCRITAS COMPLETAS.
 *
 * No se arman con template strings (`bg-${f}-${p}`) a propósito: Tailwind
 * escanea texto, no evalúa JS, y una clase compuesta en runtime no se genera.
 * Este archivo lo ve el escaneo de la galería (dev/gallery/**), no el de
 * producción — ver vite.gallery.config.js.
 */

export interface MuestraColor {
  paso: number;
  clase: string;
  /** Clase de texto legible sobre ese fondo. */
  texto: string;
}

export interface FamiliaColor {
  nombre: string;
  /** Para qué se usa en la app. */
  uso: string;
  pasos: MuestraColor[];
}

export const FAMILIAS_COLOR: FamiliaColor[] = [
  {
    nombre: "gray",
    uso: "Superficies y texto del modo oscuro; el neutro histórico de la app.",
    pasos: [
      { paso: 50, clase: 'bg-gray-50', texto: 'text-gray-900' },
      { paso: 100, clase: 'bg-gray-100', texto: 'text-gray-900' },
      { paso: 200, clase: 'bg-gray-200', texto: 'text-gray-900' },
      { paso: 300, clase: 'bg-gray-300', texto: 'text-gray-900' },
      { paso: 400, clase: 'bg-gray-400', texto: 'text-gray-900' },
      { paso: 500, clase: 'bg-gray-500', texto: 'text-white' },
      { paso: 600, clase: 'bg-gray-600', texto: 'text-white' },
      { paso: 700, clase: 'bg-gray-700', texto: 'text-white' },
      { paso: 800, clase: 'bg-gray-800', texto: 'text-white' },
      { paso: 900, clase: 'bg-gray-900', texto: 'text-white' },
    ],
  },
  {
    nombre: "stone",
    uso: "Neutro cálido del panel de Pedidos: fondo del body, bordes, meta-líneas.",
    pasos: [
      { paso: 50, clase: 'bg-stone-50', texto: 'text-gray-900' },
      { paso: 100, clase: 'bg-stone-100', texto: 'text-gray-900' },
      { paso: 200, clase: 'bg-stone-200', texto: 'text-gray-900' },
      { paso: 300, clase: 'bg-stone-300', texto: 'text-gray-900' },
      { paso: 400, clase: 'bg-stone-400', texto: 'text-gray-900' },
      { paso: 500, clase: 'bg-stone-500', texto: 'text-white' },
      { paso: 600, clase: 'bg-stone-600', texto: 'text-white' },
      { paso: 700, clase: 'bg-stone-700', texto: 'text-white' },
      { paso: 800, clase: 'bg-stone-800', texto: 'text-white' },
      { paso: 900, clase: 'bg-stone-900', texto: 'text-white' },
    ],
  },
  {
    nombre: "blue",
    uso: "Color de marca: totales, enlaces, estado \"en camino\", foco.",
    pasos: [
      { paso: 50, clase: 'bg-blue-50', texto: 'text-gray-900' },
      { paso: 100, clase: 'bg-blue-100', texto: 'text-gray-900' },
      { paso: 200, clase: 'bg-blue-200', texto: 'text-gray-900' },
      { paso: 300, clase: 'bg-blue-300', texto: 'text-gray-900' },
      { paso: 400, clase: 'bg-blue-400', texto: 'text-gray-900' },
      { paso: 500, clase: 'bg-blue-500', texto: 'text-white' },
      { paso: 600, clase: 'bg-blue-600', texto: 'text-white' },
      { paso: 700, clase: 'bg-blue-700', texto: 'text-white' },
      { paso: 800, clase: 'bg-blue-800', texto: 'text-white' },
      { paso: 900, clase: 'bg-blue-900', texto: 'text-white' },
    ],
  },
  {
    nombre: "green",
    uso: "Acción primaria (Nuevo pedido), regalos y confirmaciones.",
    pasos: [
      { paso: 50, clase: 'bg-green-50', texto: 'text-gray-900' },
      { paso: 100, clase: 'bg-green-100', texto: 'text-gray-900' },
      { paso: 200, clase: 'bg-green-200', texto: 'text-gray-900' },
      { paso: 300, clase: 'bg-green-300', texto: 'text-gray-900' },
      { paso: 400, clase: 'bg-green-400', texto: 'text-gray-900' },
      { paso: 500, clase: 'bg-green-500', texto: 'text-white' },
      { paso: 600, clase: 'bg-green-600', texto: 'text-white' },
      { paso: 700, clase: 'bg-green-700', texto: 'text-white' },
      { paso: 800, clase: 'bg-green-800', texto: 'text-white' },
      { paso: 900, clase: 'bg-green-900', texto: 'text-white' },
    ],
  },
  {
    nombre: "emerald",
    uso: "Entregados y exportaciones a Excel. Desde #712 tiene los valores de green: mismo significado, un solo verde.",
    pasos: [
      { paso: 50, clase: 'bg-emerald-50', texto: 'text-gray-900' },
      { paso: 100, clase: 'bg-emerald-100', texto: 'text-gray-900' },
      { paso: 200, clase: 'bg-emerald-200', texto: 'text-gray-900' },
      { paso: 300, clase: 'bg-emerald-300', texto: 'text-gray-900' },
      { paso: 400, clase: 'bg-emerald-400', texto: 'text-gray-900' },
      { paso: 500, clase: 'bg-emerald-500', texto: 'text-white' },
      { paso: 600, clase: 'bg-emerald-600', texto: 'text-white' },
      { paso: 700, clase: 'bg-emerald-700', texto: 'text-white' },
      { paso: 800, clase: 'bg-emerald-800', texto: 'text-white' },
      { paso: 900, clase: 'bg-emerald-900', texto: 'text-white' },
    ],
  },
  {
    nombre: "red",
    uso: "Cancelaciones, errores y sin conexión.",
    pasos: [
      { paso: 50, clase: 'bg-red-50', texto: 'text-gray-900' },
      { paso: 100, clase: 'bg-red-100', texto: 'text-gray-900' },
      { paso: 200, clase: 'bg-red-200', texto: 'text-gray-900' },
      { paso: 300, clase: 'bg-red-300', texto: 'text-gray-900' },
      { paso: 400, clase: 'bg-red-400', texto: 'text-gray-900' },
      { paso: 500, clase: 'bg-red-500', texto: 'text-white' },
      { paso: 600, clase: 'bg-red-600', texto: 'text-white' },
      { paso: 700, clase: 'bg-red-700', texto: 'text-white' },
      { paso: 800, clase: 'bg-red-800', texto: 'text-white' },
      { paso: 900, clase: 'bg-red-900', texto: 'text-white' },
    ],
  },
  {
    nombre: "rose",
    uso: "Impagos y deuda previa del cliente. Desde #712 tiene los valores de red.",
    pasos: [
      { paso: 50, clase: 'bg-rose-50', texto: 'text-gray-900' },
      { paso: 100, clase: 'bg-rose-100', texto: 'text-gray-900' },
      { paso: 200, clase: 'bg-rose-200', texto: 'text-gray-900' },
      { paso: 300, clase: 'bg-rose-300', texto: 'text-gray-900' },
      { paso: 400, clase: 'bg-rose-400', texto: 'text-gray-900' },
      { paso: 500, clase: 'bg-rose-500', texto: 'text-white' },
      { paso: 600, clase: 'bg-rose-600', texto: 'text-white' },
      { paso: 700, clase: 'bg-rose-700', texto: 'text-white' },
      { paso: 800, clase: 'bg-rose-800', texto: 'text-white' },
      { paso: 900, clase: 'bg-rose-900', texto: 'text-white' },
    ],
  },
  {
    nombre: "amber",
    uso: "Salvedades, advertencias y pedidos que envejecen.",
    pasos: [
      { paso: 50, clase: 'bg-amber-50', texto: 'text-gray-900' },
      { paso: 100, clase: 'bg-amber-100', texto: 'text-gray-900' },
      { paso: 200, clase: 'bg-amber-200', texto: 'text-gray-900' },
      { paso: 300, clase: 'bg-amber-300', texto: 'text-gray-900' },
      { paso: 400, clase: 'bg-amber-400', texto: 'text-gray-900' },
      { paso: 500, clase: 'bg-amber-500', texto: 'text-white' },
      { paso: 600, clase: 'bg-amber-600', texto: 'text-white' },
      { paso: 700, clase: 'bg-amber-700', texto: 'text-white' },
      { paso: 800, clase: 'bg-amber-800', texto: 'text-white' },
      { paso: 900, clase: 'bg-amber-900', texto: 'text-white' },
    ],
  },
  {
    nombre: "yellow",
    uso: "Notas del pedido y toasts de advertencia. Desde #712 tiene los valores de amber: un solo color de atención.",
    pasos: [
      { paso: 50, clase: 'bg-yellow-50', texto: 'text-gray-900' },
      { paso: 100, clase: 'bg-yellow-100', texto: 'text-gray-900' },
      { paso: 200, clase: 'bg-yellow-200', texto: 'text-gray-900' },
      { paso: 300, clase: 'bg-yellow-300', texto: 'text-gray-900' },
      { paso: 400, clase: 'bg-yellow-400', texto: 'text-gray-900' },
      { paso: 500, clase: 'bg-yellow-500', texto: 'text-white' },
      { paso: 600, clase: 'bg-yellow-600', texto: 'text-white' },
      { paso: 700, clase: 'bg-yellow-700', texto: 'text-white' },
      { paso: 800, clase: 'bg-yellow-800', texto: 'text-white' },
      { paso: 900, clase: 'bg-yellow-900', texto: 'text-white' },
    ],
  },
  {
    nombre: "orange",
    uso: "En preparación, transportista asignado y entrega programada.",
    pasos: [
      { paso: 50, clase: 'bg-orange-50', texto: 'text-gray-900' },
      { paso: 100, clase: 'bg-orange-100', texto: 'text-gray-900' },
      { paso: 200, clase: 'bg-orange-200', texto: 'text-gray-900' },
      { paso: 300, clase: 'bg-orange-300', texto: 'text-gray-900' },
      { paso: 400, clase: 'bg-orange-400', texto: 'text-gray-900' },
      { paso: 500, clase: 'bg-orange-500', texto: 'text-white' },
      { paso: 600, clase: 'bg-orange-600', texto: 'text-white' },
      { paso: 700, clase: 'bg-orange-700', texto: 'text-white' },
      { paso: 800, clase: 'bg-orange-800', texto: 'text-white' },
      { paso: 900, clase: 'bg-orange-900', texto: 'text-white' },
    ],
  },
  {
    nombre: "purple",
    uso: "Quién cargó el pedido (preventista).",
    pasos: [
      { paso: 50, clase: 'bg-purple-50', texto: 'text-gray-900' },
      { paso: 100, clase: 'bg-purple-100', texto: 'text-gray-900' },
      { paso: 200, clase: 'bg-purple-200', texto: 'text-gray-900' },
      { paso: 300, clase: 'bg-purple-300', texto: 'text-gray-900' },
      { paso: 400, clase: 'bg-purple-400', texto: 'text-gray-900' },
      { paso: 500, clase: 'bg-purple-500', texto: 'text-white' },
      { paso: 600, clase: 'bg-purple-600', texto: 'text-white' },
      { paso: 700, clase: 'bg-purple-700', texto: 'text-white' },
      { paso: 800, clase: 'bg-purple-800', texto: 'text-white' },
      { paso: 900, clase: 'bg-purple-900', texto: 'text-white' },
    ],
  },
  {
    nombre: "indigo",
    uso: "Marcar visita, cambio/devolución y entrega+pago.",
    pasos: [
      { paso: 50, clase: 'bg-indigo-50', texto: 'text-gray-900' },
      { paso: 100, clase: 'bg-indigo-100', texto: 'text-gray-900' },
      { paso: 200, clase: 'bg-indigo-200', texto: 'text-gray-900' },
      { paso: 300, clase: 'bg-indigo-300', texto: 'text-gray-900' },
      { paso: 400, clase: 'bg-indigo-400', texto: 'text-gray-900' },
      { paso: 500, clase: 'bg-indigo-500', texto: 'text-white' },
      { paso: 600, clase: 'bg-indigo-600', texto: 'text-white' },
      { paso: 700, clase: 'bg-indigo-700', texto: 'text-white' },
      { paso: 800, clase: 'bg-indigo-800', texto: 'text-white' },
      { paso: 900, clase: 'bg-indigo-900', texto: 'text-white' },
    ],
  },
];
