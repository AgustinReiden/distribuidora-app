---
description: Genera y guarda en la base el análisis gerencial mensual (Tucumán, Taco Pozo y Red) usando los datos en vivo del RPC reporte_gerencial
argument-hint: "[YYYY-MM]  (mes a analizar; vacío = mes calendario anterior)"
---

Sos el analista financiero de Distribuidora Manaos. Tu tarea es generar el **análisis gerencial del mes** indicado y **guardarlo en la base** para que aparezca en la vista web de Reportes Gerenciales.

Mes a analizar: **$ARGUMENTS**
- Si está vacío, usá el mes calendario **anterior** al actual (no el mes en curso).
- Derivá `p_desde` = primer día del mes (`YYYY-MM-01`) y `p_hasta` = último día del mes. Si el mes pedido es el mes en curso, usá la fecha de hoy como `p_hasta` y tratalo como **período parcial**.

## 1. Obtener los datos (vía MCP de Supabase)

Proyecto Supabase: `hmuchlzmuqqxcldbzkgc`. Para cada uno de los **tres ámbitos** ejecutá el RPC y leé el JSON:

```sql
SELECT reporte_gerencial(1,    '<p_desde>', '<p_hasta>');  -- Tucumán
SELECT reporte_gerencial(2,    '<p_desde>', '<p_hasta>');  -- Taco Pozo
SELECT reporte_gerencial(NULL, '<p_desde>', '<p_hasta>');  -- Red (consolidado)
```

El JSON trae: `kpis`, `mensual`, `vendedores`, `categorias`, `top_productos`, `top_clientes`, `cobranza`, `serie_diaria`, `flags`.

## 2. Convenciones de análisis (NO desviarse)

- **Venta** = pedidos entregados (`kpis.venta`). **Margen comercial** = venta − CMV. **Margen neto** = − bonificaciones.
- **Bonificaciones** = producto regalado (costo real, ingreso 0). Si son altas respecto de la venta, es la palanca/costo a vigilar.
- **Comisiones** = 2% sobre `kpis.base_comision` (pedidos no cancelados). **Contribución** = margen neto − mermas − comisiones (antes de gastos de estructura, que no están en el sistema).
- **Alerta de costos:** si `flags.pct_sin_costo` > 1, advertí que el margen está **sobreestimado** (~ese % de la venta sin costo cargado) y que el margen real es algo menor.
- Marcá **período parcial** si corresponde. Tono ejecutivo, español rioplatense, concreto. **No inventes** nada que no esté en el JSON; las cifras deben salir del RPC.

## 3. Estructura del análisis (markdown, por ámbito)

```
## Resumen ejecutivo
(2–3 párrafos: venta, márgenes, lo que mueve el resultado, contribución estimada)

## Hallazgos y recomendaciones
- **<hallazgo>** — <dato>. *Recomendación:* <acción>.
(4–6 puntos accionables)

## Alertas de datos
(solo si las hay: productos sin costo, mermas anómalas, concentración, etc.)
```

## 4. Guardar en la base

Para cada ámbito, persistí el **markdown** + el **snapshot de datos** en una sola llamada (el RPC se vuelve a evaluar y guarda el JSON congelado):

```sql
SELECT guardar_analisis_mensual(
  1,                      -- sucursal_id (1 Tucumán, 2 Taco Pozo, NULL Red)
  '<p_desde>',            -- periodo (se normaliza al 1° del mes)
  $analisis$
## Resumen ejecutivo
...markdown redactado...
$analisis$,
  reporte_gerencial(1, '<p_desde>', '<p_hasta>')   -- snapshot
);
```

Repetí para `2` y `NULL`. Usá dollar-quoting (`$analisis$ ... $analisis$`) para que el markdown con comillas/saltos no rompa el SQL.

## 5. Confirmar

Avisá al usuario: los 3 análisis quedaron guardados para el mes `<periodo>`, con una línea-resumen de cada sucursal y de la red. Recordale que ya se ven en la web entrando a **Reportes Gerenciales → (sucursal) → (mes)**.
