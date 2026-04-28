// Boot del tool registry. Importá esto y llamá `registerAllTools()` UNA vez
// (típicamente al arrancar la edge function o al inicio del test). El flag
// _registered evita re-registrar y disparar el throw de duplicados.
//
// Diseño: registro central explícito (en lugar de auto-registro al importar
// cada tool). Más controlable y testeable — los tests pueden llamar
// _clearToolsForTests() y re-registrar a voluntad.

import { registerTool } from "./registry.ts";
import { buscarClienteTool } from "./common/buscar_cliente.ts";
import { buscarProductoTool } from "./common/buscar_producto.ts";
import { fichaClienteTool } from "./common/ficha_cliente.ts";
import { fichaProductoTool } from "./common/ficha_producto.ts";
import { listarCategoriasTool } from "./common/listar_categorias.ts";
import { productosPorCategoriaTool } from "./common/productos_por_categoria.ts";
import { misClientesTool } from "./preventista/mis_clientes.ts";
import { sugerirVisitasRfmTool } from "./preventista/sugerir_visitas_rfm.ts";
import { historicoClienteTool } from "./preventista/historico_cliente.ts";
import { productosRecurrentesTool } from "./preventista/productos_recurrentes.ts";
import { miRecorridoHoyTool } from "./transportista/mi_recorrido_hoy.ts";
import { recorridoResumenTool } from "./transportista/recorrido_resumen.ts";
import { ventasPeriodoTool } from "./admin/ventas_periodo.ts";
import { pendientesPagoTool } from "./admin/pendientes_pago.ts";
import { historicoPagosClienteTool } from "./admin/historico_pagos_cliente.ts";
import { comprasPeriodoTool } from "./admin/compras_periodo.ts";

let _registered = false;

export function registerAllTools(): void {
  if (_registered) return;
  registerTool(buscarClienteTool);
  registerTool(buscarProductoTool);
  registerTool(fichaClienteTool);
  registerTool(fichaProductoTool);
  registerTool(listarCategoriasTool);
  registerTool(productosPorCategoriaTool);
  registerTool(misClientesTool);
  registerTool(sugerirVisitasRfmTool);
  registerTool(historicoClienteTool);
  registerTool(productosRecurrentesTool);
  registerTool(miRecorridoHoyTool);
  registerTool(recorridoResumenTool);
  registerTool(ventasPeriodoTool);
  registerTool(pendientesPagoTool);
  registerTool(historicoPagosClienteTool);
  registerTool(comprasPeriodoTool);
  _registered = true;
}

/** Test helper: resetea el flag para que los tests puedan re-registrar. */
export function _resetRegisterFlagForTests(): void {
  _registered = false;
}

export {
  _clearToolsForTests,
  getAllTools,
  getTool,
  getToolsForRole,
  invokeTool,
  registerTool,
} from "./registry.ts";

export { canInvoke } from "./permissions.ts";

export type {
  InferToolParams,
  InferToolResult,
  Tool,
  ToolContext,
  ToolResult,
} from "./base.ts";

export type { BotRol } from "../types.ts";
