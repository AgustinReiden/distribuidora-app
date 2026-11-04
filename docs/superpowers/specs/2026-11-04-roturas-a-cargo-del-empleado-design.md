# Roturas a cargo del empleado (entrega 5 de gastos y personal)

Diseño acordado con el dueño el 2026-11-04. Amplía la §4.5 de
`2026-10-28-gastos-y-cuentas-del-personal-design.md`. El plan general está en #1332.

## Para qué

Hasta hoy nadie pagó mercadería rota o perdida. El dueño quiere empezar a cobrarla: cuando se
pierde mercadería por culpa de alguien, el admin se la carga a uno o más empleados y la
liquidación se la descuenta del sueldo, como ya pasa con la mercadería que se llevan con
adelanto de sueldo.

**Éxito:** el admin carga la pérdida, decide en el mismo momento quién la paga y cuánto, y eso
aparece solo en la cuenta de cada empleado y en su próxima liquidación.

**Anti-objetivos:**
- Que se le cobre a alguien sin que el admin lo haya elegido.
- Que corregir un error obligue a mover stock.
- Que el encargado o el depósito vean montos o la lista de empleados con datos de cuenta.

## Lo que decidió el dueño

1. **Decide el admin, en el momento de cargar la pérdida.** No hay un paso posterior de
   "decidir de quién es".
2. **Se cobra el costo**, el que la merma ya congela (`cantidad × mermas_stock.costo_unitario`),
   y el admin lo puede corregir.
3. **Se puede repartir** entre varios empleados, por ejemplo el chofer y el ayudante.
4. **Vale en dos lugares:**
   - **La baja de stock** (`ModalMermaStock`), que carga el admin.
   - **Al resolver una salvedad** de mercadería dañada, vencida o faltante
     (`producto_danado`, `producto_vencido`, `faltante_stock`). Resolver la salvedad no cobra
     nada por sí solo: el admin elige si se la carga a alguien y a quién.
5. Ninguna de las dos cosas es obligatoria: sin elegir a nadie, todo queda como hoy.

## Cómo funciona

### Las líneas

Cada cargo es una o más **líneas**: un empleado y un monto (> 0). Las líneas de un mismo cargo
nacen juntas, en la misma transacción que la merma o la resolución.

- **Monto por defecto:** el costo de la pérdida dividido en partes iguales entre los empleados
  elegidos; cada parte se puede cambiar. Redondeo a centavos y la diferencia a la primera línea
  **[mi decisión]**.
- **Si la suma pasa el costo**, la pantalla avisa y deja guardar **[mi decisión]**. El server no
  pone tope: el que decide es el admin.
- **Si el costo es 0 o no se conoce** (un faltante sobre un regalo no deja merma, #847; un producto
  sin costo), el monto arranca vacío y el admin lo escribe **[mi decisión]**.
- **Empleados elegibles:** los activos que el admin puede ver y que son de la sucursal de la merma
  o de las dos, con la regla de `_empleado_visible`. Nadie se carga a sí mismo, como en el resto de
  la cuenta (`guardar_empleado` paso 5).

### En la cuenta del empleado

Cada línea es un movimiento nuevo de tipo **`rotura`** (−) en `empleado_movimientos`, que apunta a
la merma (`merma_id`) o a la salvedad (`salvedad_id`), exactamente a una de las dos, con la fecha
de la pérdida y una observación con el producto y la cantidad.

- **La merma de una salvedad no la crea la resolución.** `registrar_salvedad` ya deja la fila en
  `mermas_stock` (con `salvedad_id`) al registrar una salvedad dañada, vencida o faltante, salvo el
  faltante sobre un regalo (#847). Por eso el cargo de una salvedad apunta a la **salvedad**, y su
  costo por defecto se lee de la merma viva con ese `salvedad_id` si existe; si no existe, el monto
  arranca vacío. Elegir «A cargo de empleados» no crea ni toca ninguna merma ni stock. La liquidación lo resta como cualquier movimiento desde
la última liquidación; si deja el saldo en contra, sigue en contra para la siguiente, como hoy.

### Deshacer

- **Salvedad:** `anular_salvedad` ya anula su merma; ahora además revierte cada `rotura` viva de
  esa salvedad con un movimiento que la compensa (`revierte_id`), en la misma transacción.
- **Baja de stock manual:** hoy **no existe** anular una merma manual, y este diseño no la agrega
  (mover stock y lotes de vuelta tiene sus propias reglas, `migrations/CLAUDE.md`). Para corregir un
  cargo equivocado, el admin revierte la línea desde la cuenta del empleado con «Revertir», que ya
  existe (`revertir_movimiento_empleado`, pide motivo). El stock no se toca: la pérdida fue real,
  lo que estaba mal era a quién se le cobró **[mi decisión]**.
- Si alguna vez se agrega anular una merma manual, ese camino revierte sus `rotura` igual que la
  salvedad.
- **Una `rotura` ya liquidada también se revierte** **[mi decisión]**: el movimiento que la compensa
  entra en la próxima liquidación, igual que la mercadería cuyo pago baja después de liquidado
  (§4.4 del diseño general). Ni `anular_salvedad` ni «Revertir» fallan por eso. No es el caso del
  `pago` liquidado, que la 446 bloquea porque es plata que ya salió.
- **Para cobrárselo a otro**, el admin revierte la línea equivocada y carga al que corresponde un
  «Ajuste» en contra con «+ Movimiento», que ya existe y pide observación **[mi decisión]**. No hay
  un camino para sumar una `rotura` a una merma ya cargada: el cargo nace con la merma o con la
  resolución.

### Quién ve qué

- **La sección «A cargo de empleados»** la ve sólo el admin, en la baja de stock y en «Resolver
  salvedad». El encargado puede seguir resolviendo salvedades y el depósito cargando bajas, sin
  esa sección.
- **La resolución «Descuento a Transportista»** existe hoy en `salvedades_items.estado_resolucion`
  pero no hace nada y nunca se usó (0 filas en prod). Pasa a llamarse **«A cargo de empleados»**:
  es la opción que abre el reparto, y sólo la ofrece al admin. Cambia sólo la etiqueta; el valor en
  la base sigue siendo `descuento_transportista` **[mi decisión]**, y el server exige al menos una
  línea cuando se elige y rechaza líneas con cualquier otra resolución.
- **Fuera del admin no se ve nada del cargo** **[mi decisión]**: ni la lista de mermas, ni la de
  salvedades, ni `mermas_valorizadas` muestran a quién se le cobró ni cuánto. Las `rotura` se leen
  sólo desde la cuenta del empleado, que ya es sólo de admin. Las otras resoluciones no cobran
  nada **[mi decisión]**. `cerrar_salvedades_en_lote` no cobra nunca.
- **No es retroactivo:** las 330 salvedades ya resueltas y las mermas ya cargadas quedan como están.
  Las 48 pendientes se pueden resolver con el cargo.

## Restricciones

- Las reglas de `CLAUDE.md` para funciones y tablas nuevas (REVOKE de `PUBLIC, anon`, grants
  exactos, `_tablero_hoy()` para el día), las de `migrations/CLAUDE.md` para lo que toca mermas, y
  partir del cuerpo vivo con guarda md5 al reescribir `registrar_merma_manual`, `resolver_salvedad`
  y `anular_salvedad`.
- La guarda de `revertir_movimiento_empleado` que hoy rechaza revertir ciertos tipos tiene que
  dejar revertir `rotura` de merma manual y rechazar la de salvedad (esa se deshace anulando la
  salvedad, como los faltantes de rendición).
- `registrar_merma_manual` no es idempotente (`useMermasQuery.ts`): el cargo viaja en la misma
  llamada, nunca en una segunda.
- Montos en el front con `InputMonto` (#1414).

## Lo que queda para quien construya

- Si el cargo viaja como un parámetro nuevo (`p_cargos jsonb`) de las RPCs existentes o como una
  RPC aparte en la misma transacción; las columnas exactas (`merma_id`, `salvedad_id`) y sus
  CHECKs.
- El texto exacto de la sección y del aviso de suma mayor al costo.
- Los checks de integridad (que cada `rotura` viva apunte a una merma o salvedad viva) se anotan en
  #1330/#1426, no se suman acá.
