# Cargo de envío: lo que falta sobre la versión de main

Fecha: 2026-10-26 · Estado: aprobado por el dueño en chat ("armá lo que falta sobre la versión de
main, mismas reglas acordadas"). Las adaptaciones al modelo de main son decisiones del diseñador y
están marcadas.

## Contexto

`main` ya tiene el cargo de envío (PR #1226, issue #1220, mig 389, aplicada en prod el 2026-10-26):

- `politicas_comerciales.modo_minimo_pedido` ∈ `bloquear | cargo | escalas`, `monto_minimo_pedido`,
  `monto_envio_gratis`, `cargo_envio_pedido`. Las tres sucursales siguen en `bloquear` con todo en 0.
- `pedidos.cargo_envio` (lo pactado). `pedidos.total = SUM(subtotal) + (SUM(subtotal) > 0 ? cargo_envio : 0)`.
  El rechazo total ya deja el cargo sin cobrar y anular la salvedad lo devuelve.
- Regla pura `pedido_cargo_envio(total, sucursal)` ↔ `cargoEnvioPedido` en `src/utils/montoMinimo.ts`.
- Alta web, offline y bot cobran el cargo. Cancelar y pasar a VB lo ponen en 0. `cambiar_cliente_pedido`
  lo conserva. La edición lo conserva siempre.
- Carrito (`ModalPedido`) ya muestra el aviso y el total con envío; `/configuracion` ya edita la política.

## Lo que falta (reglas acordadas con el dueño el 2026-10-16)

1. **Edición.** El cargo se recalcula sólo si la edición **cambia la franja** (debajo/arriba del umbral
   de envío gratis, medido con la política vigente). Preventista: automático. Admin o encargado: un
   diálogo dentro del modal pregunta "¿Agregar/Sacar envío de $X?" y decide. Sin cruce, no se toca.
   Si la sucursal hoy no cobra cargo, no se recalcula nada. Un pedido que nació sin cargo de política
   nunca lo gana al editarse.
2. **Reportes.** "Venta" es de productos: `GREATEST(total - cargo_envio, 0)`. Lo que es plata a cobrar
   (saldo, cobranza, deuda, recorridos, rendiciones, jornadas del transportista) sigue con `total`.
   Comisiones y metas ya salen de las líneas. Bloque **Envíos** en el reporte gerencial: recaudado,
   pedidos que pagaron, que salieron gratis, bonificados por el admin, % que pagó.
3. **IVA en FC.** El cargo es precio final. ZZ: todo neto. FC: neto = `round(cargo / 1.21, 2)`, IVA =
   cargo − neto. Entra en `total_neto`/`total_iva` (así `posicion_fiscal` declara el IVA del envío);
   `total_real` no lo incluye. Se usa el cargo **efectivo** (0 si el pedido quedó sin productos).
4. **Comanda, recibo A4 y hoja de ruta.** Renglón "Envío" antes de TOTAL cuando el cargo efectivo > 0.
5. **Bot.** La vista previa respeta el modo (en `cargo` no rechaza por mínimo; en `escalas` rechaza bajo
   el mínimo), muestra el cargo y el total a pagar; si la política cambió entre la vista previa y la
   confirmación, la confirmación pide volver a previsualizar.

## Huecos de main que se corrigen de paso (anti-objetivos acordados)

6. **Cobro "pagado" en el alta**: hoy registra el total sin cargo y el pedido queda parcial debiendo el
   envío. Usa el total del server (`total` de productos + `cargo_envio` devuelto).
7. **Reintento idempotente** (respuesta perdida): el front compara el total guardado con el enviado; con
   cargo no coinciden y el pedido queda como fallido terminal (y se duplica). Comparar `total − cargo`.
8. **Entrega con salvedad parcial**: "Total efectivo a cobrar" no suma el cargo; el chofer cobra de menos.
9. **Pedido sin productos** (sólo regalos) en modo `cargo`: hoy paga cargo y VENTA-A queda en rojo
   (la fórmula de VENTA-A lo lleva a 0). Un pedido sin productos nunca paga cargo.

## Adaptación al modelo de main (decisiones del diseñador)

- **Estado del cargo.** Columna nueva `pedidos.cargo_envio_estado` ∈ `no_aplica | cobrado | gratis |
  bonificado`. La fija el alta: si la política de la sucursal cobra cargo (modo `cargo` o `escalas` y
  `cargo_envio_pedido > 0`), `cobrado` o `gratis`; si no, `no_aplica`. VB y canje: `no_aplica`. La
  cambia la edición (incluido `bonificado` por decisión del admin). El rechazo total no la cambia (lo
  resuelve la fórmula de main). CHECK: `cobrado` ⇔ `cargo_envio > 0`. Hace falta para la regla 1
  ("nunca gana cargo") y para las métricas de la regla 2 ("gratis" no se deduce después).
- **Umbral de la franja.** Modo `cargo`: `monto_minimo_pedido`. Modo `escalas`: `monto_envio_gratis`
  (en la edición no se valida el mínimo: la política rige el alta, trampa 8). `debajo` ⇔
  `0 < total < umbral`.
- **Cambio de cliente**: queda como en main (conserva el cargo).
- **Rechazo de la confirmación del bot** si el cargo cambió, como hace la 373 con la promo.

## Anti-objetivos

- Que el cargo cuente como venta del preventista, comisión, meta o ranking.
- Que el chofer o el preventista cobren sin el cargo.
- Que el día del deploy cambie un número de un reporte (hoy no hay ningún pedido con cargo).
- Que una sucursal que no cobra cargo vea la palabra "envío".
