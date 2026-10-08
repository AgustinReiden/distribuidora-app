// Casos de la evaluación de modelos del bot (#979). Cada caso es una pregunta
// que un usuario real le haría al bot, con qué herramienta(s) sería razonable
// que use. Se corren con `_eval/correr.ts` contra datos reales (lectura).
//
// Los de origen "registro" salen del log de producción (preguntas del admin,
// reescritas como una sola pregunta cuando eran un seguimiento). Los de origen
// "escrita" los escribimos a partir de lo que pidió el dueño.

export type RolEval = "admin" | "preventista" | "encargado";

/**
 * Valor esperado de un argumento. Además de un literal (se compara sin mirar
 * mayúsculas ni tildes), admite:
 *  - "{hoy}" "{ayer}" "{hace30}" "{inicioMes}" "{mesPasadoDesde}" "{mesPasadoHasta}":
 *    fechas YYYY-MM-DD en America/Argentina/Buenos_Aires, resueltas al correr.
 *  - { contiene: "manaos" }: subcadena, sin mirar mayúsculas ni tildes.
 */
export type ArgEsperado = string | number | boolean | { contiene: string };

export interface CasoEval {
  id: string;
  rol: RolEval;
  /**
   * `{cliente}` se reemplaza al correr por un cliente real de la cartera del
   * usuario de la evaluación (el de más entregas en el año): un nombre fijo
   * puede no ser de su cartera, y el caso fallaría por permisos y no por el
   * modelo.
   */
  pregunta: string;
  origen: "registro" | "escrita";
  /** Herramientas aceptables: el caso pasa la elección si se llamó al menos una. */
  herramientas: string[];
  /** Subconjunto de argumentos que debe tener la llamada que coincide. */
  args?: Record<string, ArgEsperado>;
  /** Hay un default razonable (ej. sin período = últimos 30 días): no vale sólo repreguntar. */
  debeResponderSinPreguntar?: boolean;
  /** Se espera que NO llame a ninguna herramienta (ej. un saludo). */
  ninguna?: true;
  /** Herramientas que, si se llaman, hacen fallar el caso (alcance por rol). */
  prohibidas?: string[];
}

// Herramientas que sólo admin puede usar: un preventista no debería llegar a ellas.
const SOLO_ADMIN = [
  "ventas_periodo",
  "ventas_por_preventista",
  "ranking_preventistas_por_producto",
  "compras_periodo",
];

export const CASOS: CasoEval[] = [
  // ---- Preguntas reales del admin (log de producción) ----
  {
    id: "a01_catalogo",
    rol: "admin",
    origen: "registro",
    pregunta: "Armame un catálogo con todos los productos que hay a la venta y sus precios",
    herramientas: [
      "productos_por_categoria",
      "listar_categorias",
      "stock_y_ventas",
      "buscar_producto",
    ],
    debeResponderSinPreguntar: true,
  },
  {
    id: "a02_manaos_3l_cola_mes",
    rol: "admin",
    origen: "registro",
    pregunta: "Decime cuánto vendimos de Manaos de 3 litros sabor cola en el último mes",
    herramientas: ["stock_y_ventas", "ranking_preventistas_por_producto", "ventas_periodo"],
    debeResponderSinPreguntar: true,
  },
  {
    id: "a03_ventas_30d_productos",
    rol: "admin",
    origen: "registro",
    pregunta:
      "Necesito un reporte de las ventas de los últimos 30 días, cuáles son los productos ordenados de mayores ventas a menor",
    herramientas: ["ventas_periodo"],
    args: { desde: "{hace30}", hasta: "{hoy}" },
    debeResponderSinPreguntar: true,
  },
  {
    id: "a04_sin_venta_con_stock",
    rol: "admin",
    origen: "registro",
    pregunta:
      "Cuáles son los productos que en estos últimos 30 días no se vendieron y figuran con stock",
    herramientas: ["productos_sin_venta_con_stock"],
    args: { dias: 30 },
    debeResponderSinPreguntar: true,
  },
  {
    id: "a05_stock_manaos_3l",
    rol: "admin",
    origen: "registro",
    pregunta: "Cuál es el stock de Manaos de 3 lts?",
    herramientas: ["stock_y_ventas", "buscar_producto"],
    debeResponderSinPreguntar: true,
  },
  {
    id: "a06_stock_gaseosas",
    rol: "admin",
    origen: "registro",
    pregunta: "Cuál es el stock de gaseosas?",
    herramientas: ["stock_y_ventas", "productos_por_categoria"],
    debeResponderSinPreguntar: true,
  },
  {
    id: "a07_mejores_clientes",
    rol: "admin",
    origen: "registro",
    pregunta: "Cuáles son nuestros 5 mejores clientes?",
    herramientas: ["ranking_clientes"],
    args: { orden: "mayores", limit: 5 },
    debeResponderSinPreguntar: true,
  },
  {
    id: "a08_volumen_diego_ruiz",
    rol: "admin",
    origen: "registro",
    pregunta: "Cuál es el volumen de compra de {cliente}?",
    herramientas: [
      "ranking_clientes",
      "historico_pedidos_cliente",
      "ficha_cliente",
      "resumen_cliente_visita",
    ],
    debeResponderSinPreguntar: true,
  },
  {
    id: "a09_ventas_y_stock_30d",
    rol: "admin",
    origen: "registro",
    pregunta:
      "Haceme un reporte de venta de los últimos 30 días e indicame el stock actual de cada producto",
    herramientas: ["stock_y_ventas", "ventas_periodo"],
    debeResponderSinPreguntar: true,
  },
  {
    id: "a10_stock_manaos",
    rol: "admin",
    origen: "registro",
    pregunta: "Detallame el stock actual de los productos manaos",
    herramientas: ["stock_y_ventas", "buscar_producto", "productos_por_categoria"],
    debeResponderSinPreguntar: true,
  },
  {
    id: "a11_manaos_tres_sabores",
    rol: "admin",
    origen: "registro",
    pregunta:
      "Haceme un reporte de venta y stock actual de la manaos Manzana, pomelo blanco y naranja",
    herramientas: ["stock_y_ventas", "buscar_producto"],
    debeResponderSinPreguntar: true,
  },
  {
    id: "a12_zingara_proveedor",
    rol: "admin",
    origen: "registro",
    pregunta:
      "Dame el stock y reporte de venta de los últimos 30 días de los productos de Zingara (es el proveedor)",
    herramientas: ["stock_y_ventas"],
    args: { proveedor: { contiene: "zingar" } },
    debeResponderSinPreguntar: true,
  },
  {
    id: "a13_preventista_septiembre",
    rol: "admin",
    origen: "registro",
    pregunta: "Decime cuál es el preventista que más vendió en el mes de septiembre",
    herramientas: ["ventas_por_preventista"],
    // Septiembre de cualquier año: el año lo pone el modelo.
    args: { desde: { contiene: "-09-01" }, hasta: { contiene: "-09-30" } },
    debeResponderSinPreguntar: true,
  },
  {
    id: "a14_marcelo_clientes_atrasados",
    rol: "admin",
    origen: "registro",
    pregunta:
      "Del preventista Marcelo, cuáles son los clientes que compraron y no compran hace más tiempo",
    herramientas: ["clientes_atrasados", "ranking_clientes"],
    args: { preventista: { contiene: "marcelo" } },
    debeResponderSinPreguntar: true,
  },
  {
    id: "a15_cuenta_daniel_lai",
    rol: "admin",
    origen: "registro",
    pregunta: "Pasame la cuenta de cuánto debe {cliente} y qué pedidos debe",
    herramientas: [
      "pendientes_pago",
      "ficha_cliente",
      "historico_pedidos_cliente",
      "historico_pagos_cliente",
    ],
    debeResponderSinPreguntar: true,
  },

  // ---- Preventista (lo que pidió el dueño) ----
  {
    id: "p01_cliente_mas_compra",
    rol: "preventista",
    origen: "escrita",
    pregunta: "Qué productos le vendo más seguido a {cliente}?",
    herramientas: ["productos_recurrentes_cliente", "resumen_cliente_visita"],
    debeResponderSinPreguntar: true,
  },
  {
    id: "p02_cliente_menos_compra",
    rol: "preventista",
    origen: "escrita",
    pregunta: "De lo que compra {cliente}, qué es lo que menos lleva?",
    herramientas: ["productos_recurrentes_cliente", "resumen_cliente_visita"],
    debeResponderSinPreguntar: true,
  },
  {
    id: "p03_cliente_dejo_de_comprar",
    rol: "preventista",
    origen: "escrita",
    pregunta: "Qué productos dejó de comprar {cliente}? Quiero ver qué le puedo ofrecer",
    herramientas: ["productos_recurrentes_cliente", "resumen_cliente_visita"],
    debeResponderSinPreguntar: true,
  },
  {
    id: "p04_mejores_clientes",
    rol: "preventista",
    origen: "escrita",
    pregunta: "Cuáles son mis mejores clientes de los últimos 30 días?",
    herramientas: ["ranking_clientes", "mis_ventas"],
    debeResponderSinPreguntar: true,
  },
  {
    id: "p05_peores_clientes",
    rol: "preventista",
    origen: "escrita",
    pregunta: "Cuáles son mis peores clientes, los que menos me compraron este mes?",
    herramientas: ["ranking_clientes"],
    args: { orden: "menores" },
    debeResponderSinPreguntar: true,
  },
  {
    id: "p06_quienes_dejaron_de_comprar",
    rol: "preventista",
    origen: "escrita",
    pregunta: "Quiénes de mis clientes dejaron de comprar?",
    herramientas: ["clientes_atrasados", "mis_clientes"],
    debeResponderSinPreguntar: true,
  },
  {
    id: "p07_resumen_previo_visita",
    rol: "preventista",
    origen: "escrita",
    pregunta: "Voy a visitar a {cliente}, haceme un resumen para llegar preparado",
    herramientas: ["resumen_cliente_visita"],
    debeResponderSinPreguntar: true,
  },
  {
    id: "p08_mis_ventas_mes",
    rol: "preventista",
    origen: "escrita",
    pregunta: "Cuánto llevo vendido este mes?",
    herramientas: ["mis_ventas"],
    args: { desde: "{inicioMes}", hasta: "{hoy}" },
    debeResponderSinPreguntar: true,
  },
  {
    id: "p09_mis_clientes_con_deuda",
    rol: "preventista",
    origen: "escrita",
    pregunta: "Cuáles de mis clientes me deben plata?",
    herramientas: ["mis_clientes"],
    args: { con_deuda: true },
    debeResponderSinPreguntar: true,
  },
  {
    id: "p10_sin_comprar_45_dias",
    rol: "preventista",
    origen: "escrita",
    pregunta: "Qué clientes míos no compran hace más de 45 días?",
    herramientas: ["mis_clientes", "clientes_atrasados"],
    debeResponderSinPreguntar: true,
  },
  {
    id: "p11_stock_manaos",
    rol: "preventista",
    origen: "escrita",
    pregunta: "Cuánto stock hay de Manaos de 3 litros?",
    herramientas: ["stock_y_ventas", "buscar_producto"],
    debeResponderSinPreguntar: true,
  },
  {
    id: "p12_alcance_ventas_empresa",
    rol: "preventista",
    origen: "escrita",
    pregunta: "Cuánto vendió la empresa en total este mes, contando a todos los preventistas?",
    // Lo que puede ver es lo propio: o contesta con mis_ventas o dice que no tiene acceso.
    herramientas: ["mis_ventas"],
    prohibidas: SOLO_ADMIN,
  },
  {
    id: "p13_saludo",
    rol: "preventista",
    origen: "escrita",
    pregunta: "Hola, buen día!",
    herramientas: [],
    ninguna: true,
  },

  // ---- Encargado ----
  {
    id: "e01_mora_30_dias",
    rol: "encargado",
    origen: "escrita",
    pregunta: "Qué clientes nos deben hace más de 30 días?",
    herramientas: ["pendientes_pago"],
    args: { dias_atraso: 30 },
    debeResponderSinPreguntar: true,
  },
  {
    id: "e02_mercaderia_parada",
    rol: "encargado",
    origen: "escrita",
    pregunta: "Qué mercadería tenemos parada hace más de un mes?",
    herramientas: ["productos_sin_venta_con_stock"],
    debeResponderSinPreguntar: true,
  },
  {
    id: "e03_alcance_compras",
    rol: "encargado",
    origen: "escrita",
    pregunta: "Cuánto le compramos a cada proveedor este mes?",
    // compras_periodo es sólo admin: lo correcto es explicar que no tiene acceso.
    herramientas: [],
    ninguna: true,
    prohibidas: ["compras_periodo"],
  },
];
