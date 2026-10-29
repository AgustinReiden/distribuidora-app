# Gastos y cuentas del personal

Fecha: 2026-10-28 · Estado: aprobado por el dueño en chat el 2026-10-28 ("Apruebo el diseño").
Las reglas vienen de esa charla. Lo que decidió él va sin marca; lo que decidió el diseñador va
marcado **[diseñador]**, y el dueño lo revisó al aprobar.

Maqueta de referencia, con la estética de la app y nombres y números inventados:
`2026-10-28-gastos-y-personal-maquetas.html`, al lado de este archivo. Se abre en el navegador y
tiene cinco pestañas: Registrar gasto (interactiva), Rendición, Personal, Cuenta y Liquidar.

## Por qué

La app ya mide la venta, el costo de la mercadería y los costos comerciales (bonificaciones,
mermas, comisiones y notas de crédito). Llega hasta la **contribución**, y el reporte gerencial
lo dice: "antes de gastos fijos". Para saber cuánto gana la distribuidora faltan dos cosas, y
este módulo las registra:

1. **Los gastos**: desde los imputables a un vehículo hasta la librería.
2. **El personal**: el sueldo de cada empleado y su cuenta, o sea lo que la empresa le debe y lo
   que él le debe a la empresa.

El **estado de resultados** que los usa es el proyecto siguiente y va en su propio issue. El
dueño ya eligió la forma: una sucursal por vez, contra el mes anterior. Este módulo deja los
datos listos para esa pantalla, pero no la construye.

## Qué hay hoy

- **Sueldos**: se pactan por persona, con un fijo semanal o mensual. Los preventistas cobran
  además la comisión que calcula la app. Un admin o el encargado los anota fuera de la app.
- **Empleados**: no existen como tales. Lo único es `perfiles`, que son los usuarios con login.
  Hay gente que trabaja y no tiene usuario, como un ayudante del camión o alguien de depósito.
- **Comisiones**: `calcular_comisiones` las calcula en vivo con `comision_reglas` y los defaults
  de `politicas_comerciales`. Toma el período por `pedidos.fecha`. No queda registrado qué se
  pagó ni cuándo. Según el dueño, hasta hoy la comisión se paga en el mes en que se entrega el
  pedido.
- **Adelanto de sueldo**: es una forma de pago no dineraria (mig 273). Se usa en la ficha de
  cliente del empleado cuando se lleva mercadería. Se usó 8 veces y nada registra que después se
  le descuente.
- **Gastos de la rendición**: `rendicion_gastos` guarda descripción y monto en texto libre, "sin
  impacto en caja". En producción la tabla tiene 0 filas.
- **Rendición**: la vista y `ModalCerrarRendicion` muestran cobrado, entregado y diferencia, más
  el desglose por forma de pago. No calculan cuánto efectivo tiene que entregar el transportista.
- **Vehículos**: no existen. `recorridos.distancia_total` guarda los km que estima el
  optimizador, no los recorridos de verdad.
- **Compras**: son sólo de mercadería y siempre mueven stock. Una factura de otra cosa no se
  puede cargar.
- **Tesorería**: no hay cajas, bancos ni cuentas por pagar. El circuito de la plata es este: el
  transportista le rinde al admin, el admin le rinde a la oficina, y la oficina junta las cajas
  de varias empresas y lleva aparte caja y bancos.

## Objetivos

1. **Registrar un gasto.** Cualquier gasto de la distribuidora se carga con rubro, monto,
   comprobante, sucursal (o compartido), mes al que corresponde (o repartido en varios),
   vehículo si aplica y con qué plata se pagó.
2. **Integrar la rendición.** Un gasto que el transportista pagó con la plata del día se registra
   como gasto y se descuenta del **efectivo a entregar**.
3. **Llevar la cuenta de cada empleado.** La cuenta tiene:
   - el arreglo (sueldo fijo, frecuencia y si comisiona);
   - los movimientos: sueldo, comisiones, mercadería, roturas, reintegros, pagos y ajustes;
   - las liquidaciones por período, con las comisiones congeladas;
   - el saldo.
4. **Dejar la base** para el estado de resultados (mes imputado y grupos de rubros), el control
   de vehículos (litros y km), el GPS (lecturas de km) y la liquidación formal (aguinaldo y
   cargas sociales como conceptos nuevos).

## Fuera de este proyecto

- **Estado de resultados**: la pantalla va en un issue aparte. Acá sólo se guardan los datos que
  va a usar.
- **Tesorería**: cajas, bancos, cuentas por pagar y saldo con proveedores de gastos. "La oficina"
  es una sola opción, sin saber de qué cuenta salió la plata.
- **Liquidación formal de sueldos**: aguinaldo, vacaciones, cargas sociales y recibos. Queda la
  base, ver "Personal".
- **Conexión con el GPS SEMEGA**: va en un issue aparte, después de este módulo. No tiene API
  pública; el camino es pedirle una clave al proveedor o importar el Excel mensual de km por
  vehículo.
- **Fotos de comprobantes**: se guardan en otro servidor.
- **Gastos fijos automáticos**: alquiler, expensas y similares se cargan a mano cada mes.
- **Uso sin conexión**: gastos, liquidaciones y movimientos son en línea, como las mermas.
- **Que el transportista cargue gastos desde su celular** **[diseñador]**. Los carga el admin o el
  encargado al cerrar la rendición, como hoy.
- **Registrar el efectivo que el transportista entrega de verdad**, y con eso su faltante o
  sobrante. Hoy no se registra en ningún lado: el "entregado" de la rendición es la mercadería
  entregada, no la plata. El efectivo a entregar de este módulo es un cálculo. Si algún día se
  registra lo que se recibe, hay que cuidar que un gasto no reste dos veces.

## Anti-objetivos

Si pasa algo de esto, el módulo fracasa aunque funcione:

- **Contar dos veces el mismo gasto**, por ejemplo al restarlo dos veces del efectivo de la
  rendición o al cargarlo como gasto y además como reintegro.
- **Cambiar en silencio una comisión ya pagada.** Todo cambio aparece como ajuste.
- **Perder una comisión**, como la del pedido tomado el viernes y entregado el lunes.
- **Descontar dos veces la mercadería de un empleado, o no descontarla nunca.**
- **Mostrar de más**: que un admin de una sucursal vea sueldos o gastos de la otra (salvo los
  compartidos), o que el encargado vea sueldos.
- **Mover un número existente el día del deploy**: reporte gerencial, comisiones, rendiciones
  cerradas o saldos de clientes.

## Quién ve y hace qué

| Rol | Gastos | Personal y cuentas | Rendición |
|---|---|---|---|
| Admin de una sucursal | Ve, carga, edita y anula los de su sucursal. Carga **compartidos** con un aviso en amarillo. No puede cargar gastos de la otra sucursal. Ve todos los compartidos. Crea y edita rubros. | Todo lo de su sucursal: empleados, arreglos, cuentas, liquidaciones, pagos y movimientos | Como hoy, más los gastos |
| Admin de las dos | Todo, y elige Tucumán, Taco Pozo o Compartido | Todo, incluidos los empleados "de las dos" | Como hoy, más los gastos |
| Encargado | Carga gastos de su sucursal, **sin** compartido **[diseñador, aprobado en chat]**. Ve los de su sucursal que no son compartidos, y edita o anula sólo los que cargó él **[diseñador]**. No crea rubros. | No ve nada | Cierra rendiciones con gastos, como hoy |
| Transportista | — | — | En su vista de cobros ve su **efectivo a entregar** y los gastos de su rendición **[diseñador]** |
| Preventista, depósito | — | — | — |

Detalles de visibilidad:

- **Gastos compartidos**: los ven los admins de las dos sucursales, incluido el que lo cargó
  **[diseñador, aprobado en chat]**.
- **Empleados "de las dos"**: sólo los ven los admins de las dos.
- **"Un empleado" como origen del pago**: el encargado puede elegir un empleado como quien pagó
  el gasto. Para eso ve una lista de nombres, sin datos de sueldo.
- **Nadie se liquida ni se paga a sí mismo** **[diseñador]**. Un admin ve su propia cuenta, pero no
  puede liquidar, registrar pagos ni cargar movimientos a mano en el empleado vinculado a su
  usuario. Lo hace otro admin de la sucursal o uno de las dos. El dueño aprobó que los admins vean
  todo lo de su sucursal, incluidos los sueldos de los otros admins; esto es un control encima de
  eso.

## 1. Gastos

### 1.1 Rubros y grupos

El rubro es editable: el admin lo crea desde el mismo buscador del modal, sin salir. Todo rubro
pertenece a un **grupo fijo**, que define en qué renglón del resultado cae **[diseñador]**. Los
grupos son Vehículos, Inmueble, Impuestos, Administración, Bienes de uso y Otros.

- **Alcance**: los rubros son de toda la red, no de una sucursal **[diseñador]**.
- **Búsqueda por palabras parecidas**: un rubro puede tener palabras de búsqueda, por ejemplo
  "nafta", "gasoil" y "gnc" para Combustible.
- **Rubros sugeridos para el arranque**:
  - Vehículos: Combustible, Seguro, Patente, Mantenimiento y service, Peajes y estacionamiento.
  - Inmueble: Alquiler, Expensas, Luz, agua y gas.
  - Impuestos: Ingresos brutos, Tasa municipal.
  - Administración: Librería, Teléfono e internet, Limpieza, Honorarios del contador, Oficina
    central (parte de la distribuidora).
  - Bienes de uso: Vehículo, Equipos y muebles.
  - Otros: Varios.
- **Los sueldos nunca son un gasto de este módulo.** Salen de las liquidaciones. Ningún rubro se
  llama Sueldos, y el grupo de un rubro no se puede cambiar una vez que tiene gastos
  **[diseñador]**.

### 1.2 El gasto

| Campo | Regla |
|---|---|
| Fecha | La del comprobante, o la del pago si no hay comprobante. Obligatoria. Rige la posición fiscal; el resultado lo rige el mes del gasto **[diseñador]**. |
| Rubro | Obligatorio. |
| Monto total | Lo que dice el comprobante. Obligatorio, > 0. |
| Comprobante | Factura A, Factura B, Factura C, Recibo, Ticket o Sin comprobante. Obligatorio. |
| Número | Opcional. |
| Desglose fiscal | Sólo con factura A (o M): neto, IVA y alícuota, percepción de IVA, percepción de IIBB y otros impuestos que no se recuperan. Ver 1.6. |
| Sucursal | Una sucursal, o la marca **compartido**. Ver 1.7. |
| Vehículo | Opcional en cualquier rubro. Se ofrece cuando el rubro es del grupo Vehículos. |
| Litros y km del tablero | Opcionales. Sólo con Combustible. |
| Mes del gasto | Primer día de un mes. Por defecto, el mes de la fecha. |
| Repartir en N meses | Entero ≥ 1. Ver 1.5. |
| Con qué plata | La oficina, una rendición (transportista y día) o un empleado. Ver 1.4. |
| Observación | Opcional. |

- **Un gasto no se borra, se anula** **[diseñador]**. Queda con fecha, quién lo anuló y el
  motivo.
- **Quién edita y anula** **[diseñador]**:
  - El admin, cualquier gasto de su sucursal.
  - El encargado, sólo los que cargó él.
  - Un compartido, quien lo cargó o un admin de las dos. El admin de la otra sucursal lo ve, pero
    no lo toca.
  - Un gasto pagado con la plata de una rendición ya cerrada (confirmada o resuelta) se cambia sólo
    desde "Editar cierre" (ver 3).

### 1.3 El modal

Es un solo modal, `ModalGasto`, que se abre desde la vista Gastos y desde el cierre de la
rendición. Arranca con lo mínimo, y lo demás aparece según lo que se elige. El dueño pidió que no
sea largo. En la maqueta, el estado inicial mide unos 590 px; la primera versión medía 1.500.

- **Siempre visible**: rubro, monto total, fecha, comprobante, sucursal, con qué plata, la línea
  "Va al resultado de *octubre 2026* · cambiar" y "+ Agregar observación".
- **Factura A**: aparece el bloque de IVA. La alícuota se elige con botones (21, 10,5 o 27). El
  neto y el IVA se calculan solos desde el total y se pueden corregir. Hay un selector de letra (A
  o M), un link a "+ percepciones e impuestos" y un campo para el número.
- **Factura B, Factura C o Recibo**: aparece el link "+ número de comprobante".
- **Rubro del grupo Vehículos**: aparece el vehículo. Si el rubro es Combustible, aparece además
  el link "+ litros y km del tablero".
- **Seguro y Bienes de uso**: se abre solo el reparto en meses, con N sugerido (12 para Seguro, 60
  para Vehículo y 36 para Equipos). Para el resto de los rubros, el reparto se abre con
  "cambiar".
- **Ingresos brutos**: propone solo el mes anterior al de la fecha, con la pista "corresponde a la
  venta del mes anterior".
- **Compartido**: aparece el aviso en amarillo (ver 1.7).
- **Abierto desde el cierre de una rendición**: "con qué plata" ya viene fijo en esa rendición, el
  vehículo es el habitual del transportista, y el modal trabaja en borrador: el gasto se guarda con
  el cierre (ver 3).
- **Desplegables con búsqueda**: rubro, vehículo, transportista y empleado usan el patrón de
  `ui/Combobox`. Buscan sin tildes y en varios textos (patente, modelo o chofer en el vehículo).
  El de rubro agrupa por grupo y ofrece "+ Crear rubro «texto»". Las listas cortas no son
  desplegables: el IVA va en botones y el mes se cambia con flechas.
- **Esquema**: el schema Zod va co-locado en el modal (regla del repo).

### 1.4 Con qué plata

1. **La oficina**: no toca ninguna rendición ni ninguna cuenta. Es lo que paga la administración.
   Para la app es una sola caja.
2. **Una rendición** (transportista y día): se descuenta del efectivo a entregar de esa rendición
   (ver 3).
3. **Un empleado** (plata propia): queda **a su favor** en su cuenta como **reintegro** y se le
   devuelve con el sueldo (ver 4.6).

Un gasto sale de una sola de las tres. Esa es la garantía contra el doble conteo.

### 1.5 Mes del gasto y reparto

- **Mes**: el gasto va al resultado del **mes del gasto**, no al de la fecha de pago.
- **Reparto**: con "Repartir en N meses", el costo se divide en N cuotas iguales desde el mes del
  gasto. La última cuota absorbe el redondeo **[diseñador]**. Es el mismo mecanismo para un seguro
  anual, un vehículo o cualquier bien de uso: no hay un módulo aparte de amortizaciones.
- **Lo que tiene que dar este proyecto**: una función o vista que expanda los gastos a
  `(mes, sucursal o compartido, grupo, rubro, vehículo, costo)`. La va a consumir el estado de
  resultados.

### 1.6 Comprobante e IVA

- **Costo que va al resultado**: con factura A es `total − IVA − percepciones`; incluye el neto y
  los otros impuestos que no se recuperan. Con cualquier otro comprobante es el total. Es la misma
  idea que el costo real de las compras: el IVA y las percepciones son crédito, no costo.
- **Posición fiscal**: el IVA y las percepciones de las facturas A suman a `posicion_fiscal` como
  crédito, por la **fecha del comprobante**. Cambiar `posicion_fiscal` cambia una función
  existente, ver 5.
- **Facturas a nombre de otra empresa**: si una factura A salió a nombre de otra empresa del
  grupo, su IVA no es de la distribuidora. Hay que cargarla como "Sin comprobante", o como el
  tipo que corresponda sin desglose **[diseñador]**. La ayuda del campo lo explica.
- **Letra M** **[diseñador]**: da crédito igual que la A, como en las compras desde la mig 293. No
  es un botón aparte: el bloque de factura A tiene un selector "Letra A · M".
- **Compartido con factura A** **[diseñador]**: el crédito va a la sucursal donde se cargó, porque
  `posicion_fiscal` es por sucursal. Se carga desde la sucursal a cuyo nombre está la factura, y
  el aviso de compartido lo recuerda cuando el comprobante es A.

### 1.7 Compartidos

- **Para qué es**: para lo que es de las dos sucursales, como la oficina central o el contador.
  La mercadería que va de una sucursal a la otra no es un gasto compartido; ya va por
  transferencias.
- **Cómo se guarda** **[diseñador]**: la fila tiene la `sucursal_id` donde se cargó, para que se
  mantenga el aislamiento por sucursal (`sucursal_id NOT NULL`, FKs compuestas), y además la marca
  `compartido`.
- **Quién lo ve**: los admins de las dos sucursales (ver la tabla de roles).
- **Cómo se reparte**: en el estado de resultados, entre las sucursales activas según lo que
  vendió cada una en el mes. Este proyecto no hace ese cálculo, pero no tiene que impedirlo.
- **Aviso** que se muestra al marcarlo: "Gasto compartido entre Tucumán y Taco Pozo. Se reparte
  entre las dos según lo que vendió cada una en el mes, y lo ven los admins de las dos. Usalo sólo
  para lo que es de las dos, como la oficina o el contador."

### 1.8 Vista Gastos

No tiene maqueta; la arma el diseñador del plan con el estilo de la app (`PageHeader`, filtros
como pastillas, tarjetas o tabla).

- **Muestra**: los gastos de un mes por mes imputado, con el mes elegible con flechas, y el total
  por grupo arriba.
- **Filtros**: rubro, vehículo, sucursal o compartido, y con qué plata.
- **Acciones**: "Nuevo gasto", editar, anular y exportar.
- **Un gasto repartido** aparece en cada mes que toca, con su cuota y la marca "cuota 3 de 12".

## 2. Vehículos

- **Ficha**: patente (única), descripción o modelo, sucursal, activo, y los empleados que lo usan
  habitualmente. El dueño pidió asociar personal y vehículo, más para estadísticas que para gastos.
  Se guarda en el empleado como `vehiculo_id`, para que chofer y ayudante puedan compartir
  vehículo **[diseñador]**.
- **Vista** **[diseñador]**: muestra el gasto del vehículo por mes y rubro, sus cargas de
  combustible y, cuando hay datos, km por litro y costo por km.
- **Km**: hay una tabla de lecturas de km por vehículo y día, con su origen: manual, carga de
  combustible o GPS. La conexión con el GPS (issue aparte) escribe ahí. Hoy no se lleva ese
  control, y la infraestructura tiene que quedar lista igual.
- **Quién**: el admin hace el alta y la baja y ve la ficha con costos. El encargado sólo ve la
  lista, para elegir el vehículo en un gasto **[diseñador]**.

## 3. Rendición

- **Efectivo a entregar**, un concepto nuevo: es el efectivo cobrado, menos los gastos pagados con
  la plata de esa rendición (mismo transportista, día y sucursal, sin anular). Aparece en tres
  lugares:
  - la tarjeta de la vista Rendiciones;
  - el modal "Cerrar rendición";
  - la vista de cobros del transportista.
- **Lo que no cambia**: la diferencia cobrado − entregado, el desglose por forma de pago y los
  estados.
- **Cierre**: en "Cerrar rendición", los "Gastos del día" en texto libre se reemplazan por la
  lista de gastos de esa rendición, con rubro, vehículo, comprobante y monto. "Agregar gasto" abre
  `ModalGasto` con la plata ya fija y el vehículo habitual del transportista.
- **Los gastos se guardan con el cierre** **[diseñador]**. Van en la misma transacción que
  `confirmar_rendicion`, como hoy los "gastos del día". Si se cancela el cierre, no se guarda
  nada. Dentro del cierre, `ModalGasto` trabaja en modo borrador: le devuelve el gasto al cierre en
  vez de guardarlo.
- **Editar cierre**: puede agregar, cambiar o quitar gastos, y vuelve a confirmar todo en una sola
  transacción. La rendición no se "reabre": sigue el upsert de hoy y su estado no cambia. Así una
  rendición cerrada nunca cambia su efectivo a entregar sin que alguien confirme de nuevo.
- **Guardas de caja cerrada**: siguen mandando (`rendicion_dia_cerrada`,
  `control_rendicion_cerrado`, `ultima_fecha_caja_cerrada`, migs 134 y 375). Si hoy bloquean
  "Editar cierre" en un día, también bloquean los cambios de gastos de ese día.
- **Gasto cargado desde la vista Gastos con "una rendición"**: se guarda en el momento, pero sólo
  si esa rendición está pendiente. Aparece en el cierre, donde se puede corregir o quitar. Si la
  rendición ya está cerrada, se rechaza con un mensaje que manda a "Editar cierre".
- **Gasto pagado con plata propia del transportista**: no va en la rendición. Se carga con "un
  empleado" y se le reintegra con el sueldo.
- **Modal dentro de modal**: `ModalGasto` se renderiza dentro del árbol de
  `ModalCerrarRendicion`, no como hermano en el container. Así lo pide la regla del repo: un modal
  Radix disparado desde otro, como hermano, queda detrás del overlay.
- **Lo que hay que retirar**: `confirmar_rendicion` deja de recibir `p_gastos`. Hay que dropear la
  firma vieja (PGRST203). `rendicion_gastos` deja de escribirse; está vacía en producción y se
  puede dropear en la misma migración si sigue vacía.
- **Lo que hay que sumar**: los resúmenes de rendición (`obtener_resumen_rendiciones`,
  `obtener_detalle_rendicion`) suman los gastos nuevos en lugar de `rendicion_gastos`.
- **Pago de sueldos**: siempre sale de "la oficina" y no hay opción de pagarlo con la plata de una
  rendición **[diseñador]**. La maqueta todavía la muestra, pero se saca: si no, quien cierra la
  rendición, que puede ser el encargado, vería sueldos.

## 4. Personal

### 4.1 El empleado y sus vínculos

- **Ficha propia**: el empleado existe con usuario de la app o sin él.
  - Nombre y apellido.
  - Puesto: Preventista, Transportista, Ayudante, Depósito, Administración, Encargado u Otro
    **[diseñador]**.
  - Sucursal: Tucumán, Taco Pozo o las dos. Las dos sólo la elige quien tiene las dos.
  - Opcionales: CUIL, fecha de ingreso y teléfono.
  - Activo.
- **Admins**: los admins también son empleados, con su sueldo fijo.
- **Vínculos**: se ponen a mano y son opcionales. Cada uno es único: un usuario no puede estar en
  dos empleados.
  - **Usuario (`perfiles`)**: los pedidos que carga ese usuario comisionan para esta cuenta, si el
    arreglo comisiona.
  - **Ficha de cliente**: lo que se lleve pagando con "adelanto de sueldo" se le descuenta en esta
    cuenta (4.4). El cliente tiene que ser de la misma sucursal, o el empleado ser de las dos.
  - **Vehículo habitual** (ver 2).
- **Vista Personal**: tarjetas con el mismo molde que las de Clientes. Cada una muestra:
  - el puesto y la sucursal en la línea de arriba;
  - el lápiz para editar los datos y un botón para desactivar;
  - el nombre;
  - el arreglo;
  - los vínculos;
  - la pastilla "sin liquidar" cuando hay un período vencido;
  - un pie con el saldo y "Ver ficha".

  Arriba hay un buscador y los filtros Todos, Para liquidar, Con saldo e Inactivos.
- **Alta y edición**: el modal de alta pide además el primer arreglo. El de edición no lo toca:
  los cambios de arreglo van por la ficha, para que conserven la fecha de vigencia.
- **Baja**: el empleado se desactiva con una fecha de baja, no se borra. La cuenta y el historial
  quedan.

### 4.2 El arreglo

- **Qué dice**: el sueldo fijo, la frecuencia (semanal o mensual) y si comisiona.
- **Vigencia**: cada arreglo tiene la fecha desde la que vale. Un cambio crea un arreglo nuevo, y
  los pagos viejos conservan su monto.
- **Porcentaje de comisión**: no está en el arreglo. Sigue en `comision_reglas` y
  `politicas_comerciales`, como hoy.
- **Período** **[diseñador]**: el semanal va de lunes a domingo; el mensual, del primero al último
  día del mes.
- **Arranque** **[diseñador]**: los períodos de un empleado empiezan en la fecha desde la que vale
  su primer arreglo, no en la fecha de ingreso, que es un dato informativo. Así no aparecen cientos
  de períodos "sin liquidar" del pasado.
  - Para el personal que ya estaba, esa fecha es el primer día del período que todavía no se le
    pagó afuera. El alta la sugiere y explica por qué: de ahí sale el corte de las comisiones
    (4.8).
  - Para alguien nuevo, es su primer día.
  - El alta acepta un "saldo al empezar" opcional, que entra como ajuste con esa observación.
- **Prorrateo** **[diseñador]**: si el arreglo cambia a mitad de período, o el empleado entra o se
  da de baja a mitad de período, el sueldo del período se calcula por días corridos de cada
  tramo.

### 4.3 La cuenta

La cuenta es un libro de movimientos con signo. **Positivo: la empresa le debe. Negativo: él le
debe a la empresa.** El saldo es la suma.

- **Ningún movimiento se edita ni se borra.** Se corrige con un movimiento que lo revierte
  **[diseñador]**.

| Tipo | Signo | De dónde sale |
|---|---|---|
| Sueldo fijo | + | La liquidación |
| Comisión | + | La liquidación, con el detalle por pedido |
| Ajuste de comisión | ± | La liquidación (4.8) |
| Mercadería | − | Solo, desde el pago con adelanto de sueldo (4.4) |
| Rotura a su cargo | − | La baja de stock (4.5) |
| Reintegro de gasto | + | Solo, desde el gasto pagado con plata propia (4.6) |
| Pago | − | La liquidación o un pago suelto |
| Adelanto en efectivo | − | A mano, con "+ Movimiento" |
| Ajuste a favor o en contra | ± | A mano, con observación obligatoria |

El modal de la cuenta sigue la forma de la ficha del cliente:

- un encabezado con los datos y los vínculos;
- una tarjeta de saldo con la próxima liquidación estimada y los botones "Liquidar" y "+
  Movimiento";
- una tarjeta con el arreglo vigente, el anterior y "Cambiar arreglo";
- las pestañas Movimientos, Liquidaciones y Arreglos.

### 4.4 Mercadería

- **Cuándo entra**: cuando se registra un pago con `forma_pago = 'adelanto_sueldo'` sobre un
  cliente vinculado a un empleado. Ahí se crea el movimiento de mercadería.
- **Cliente sin vínculo**: la RPC que registra el pago rechaza el adelanto de sueldo, y el modal
  lo avisa antes de mandarlo **[diseñador]**. Hoy el pago se acepta y nadie lo descuenta, que es
  justo el problema.
- **El movimiento sigue al pago, no lo copia.** Un pago puede bajar por una salvedad sobre la
  boleta (migs 165-168 y 276) o borrarse, porque `eliminarPago` hace un DELETE por REST. Si el
  monto baja o el pago se borra, la cuenta recibe un movimiento que lo compensa: se agrega un
  movimiento nuevo y nunca se edita el anterior. Así no importa que el pago ya haya entrado en una
  liquidación. Lo resuelve un trigger sobre `pagos` en el alta, el cambio de monto y el borrado.
- **Los 8 pagos históricos** con adelanto de sueldo no generan movimientos: ya se descontaron
  fuera de la app **[diseñador]**.

### 4.5 Roturas a su cargo

- **Dónde se carga**: la baja de stock (`ModalMermaStock`) suma un campo opcional, "A cargo de un
  empleado", con un buscador. Lo ve sólo el admin.
- **Monto**: por defecto es el costo de la merma (`cantidad × costo_unitario`, el snapshot que ya
  tiene `mermas_stock`) y se puede corregir.
- **Movimiento**: crea uno de rotura que apunta a la merma. Si la merma se anula
  (`mermas_stock.anulada_at`), se revierte.
- **Prioridad**: el dueño la puso como "eventualmente". Puede ir en el último paquete.

### 4.6 Reintegros

Un gasto con "un empleado" como origen crea un reintegro a favor de ese empleado. Si el gasto se
anula, o se edita el monto o el empleado, el reintegro se revierte o se corrige con un movimiento
nuevo, con la misma regla que 4.4.

### 4.7 Liquidar

- **Qué es**: el acto que cierra un período de un empleado. Suma a la cuenta el sueldo del
  período, las comisiones y los ajustes, y registra el pago en la misma acción. El botón es
  "Confirmar y registrar el pago".
- **Lo que muestra**:
  - el sueldo fijo del período;
  - las comisiones, con la cantidad de pedidos, la base y "ver pedidos";
  - los ajustes de comisión;
  - los movimientos desde la última liquidación (mercadería, roturas, reintegros, adelantos);
  - el saldo anterior;
  - el total **a pagar**, que es el saldo que quedaría.
- **Pago parcial**: el monto que se paga se puede cambiar. Si se paga menos, lo que falta queda a
  su favor. Si se paga 0, se liquida ahora y se paga después con un pago suelto.
- **Con qué plata**: siempre la oficina (ver 3).
- **Una liquidación por empleado y período.**
- **Orden** **[diseñador]**: los períodos se liquidan en orden. "Liquidar" propone el período
  pendiente más viejo.
- **Anulación** **[diseñador]**: se puede anular sólo la última liquidación de cada empleado.
  Revierte sus movimientos, incluido el pago, y libera los pedidos para la próxima.
- **Pendientes en la vista Personal**: la pastilla "sin liquidar" aparece cuando terminó un
  período y no se liquidó.

### 4.8 Comisiones congeladas

- **Qué entra**: los pedidos entregados **hasta el último día del período** y todavía no
  liquidados, que cumplan las tres condiciones:
  - `pedidos.usuario_id` es el usuario vinculado;
  - son de las sucursales del empleado;
  - el arreglo vigente comisiona.
- **Qué fecha cuenta** **[diseñador]**: la entrega, `pedidos.fecha_entrega`. Así el pedido del
  viernes que se entrega el lunes entra en la semana del lunes y no se pierde.
- **Corte con lo que se pagó afuera**: hasta hoy la comisión se pagó en el mes en que se entregó el
  pedido; lo confirmó el dueño. Por eso el corte va por fecha de entrega:
  - lo entregado antes del arranque del empleado (4.2) se da por pagado afuera;
  - lo entregado desde el arranque se liquida en la app, aunque el pedido se haya tomado antes.

  Como el arranque es el primer día de un período que todavía no se pagó, no se paga nada dos veces
  ni se pierde nada.
- **Cómo se calcula la comisión de cada pedido**: con la misma regla que `calcular_comisiones`.
  - Las reglas por origen de precio, producto o categoría, con vigencia por `pedidos.fecha`.
  - La definición de venta por vendedor de CLAUDE.md: entregado, canal distinto de `cambio`, sin
    VB, sin el envío y sin bonificaciones.
  - Sin los pedidos pagados con adelanto de sueldo.

  Hay que sacar la comisión por pedido a una función que usen las dos. Si no, nacen dos
  definiciones.
- **Al confirmar**: se congela cada línea del pedido con su base, su porcentaje y la regla que
  aplicó, y el pedido queda liquidado **[diseñador]**.
- **Ajustes**: en cada liquidación siguiente se revisan los pedidos ya liquidados que cambiaron
  después. La diferencia entra como **ajuste**, con el pedido y el motivo, y se congela el valor
  nuevo. Una comisión pagada nunca cambia sin dejar rastro.
  - **Sí dispara un ajuste**: que cambie la **base** de una línea (salvedad, edición,
    cancelación). Se recalcula con el porcentaje congelado de esa línea **[diseñador]**.
  - **Línea nueva** en un pedido ya liquidado: se calcula con la regla vigente a `pedidos.fecha`,
    como hoy.
  - **No dispara un ajuste**: editar una regla de comisión o un porcentaje, aunque tenga vigencia
    hacia atrás. Lo que ya se liquidó queda como se liquidó.
- **La vista Comisiones no cambia**: sigue mostrando por `pedidos.fecha`. Su total del mes puede
  no coincidir con lo liquidado en el mes, porque uno toma la fecha del pedido y el otro la de
  entrega. Conviene una línea que lo aclare en la vista o en el modal **[diseñador]**.

### 4.9 Base para crecer

- **Conceptos**: la liquidación se arma por conceptos (sueldo fijo, comisión, ajuste). Sumar
  aguinaldo, vacaciones o cargas sociales tiene que ser agregar un concepto, no rehacer las
  tablas.
- **Datos laborales**: la ficha ya tiene CUIL y fecha de ingreso para cuando haga falta.
- **Costo del personal para el estado de resultados**: es el devengado, o sea sueldo y comisión
  por mes. No es lo pagado.

## 5. Lo que tiene que respetar

Son reglas del repo que muerden en este módulo.

- **Migraciones**: el número se reserva al aplicar, no al escribir; es la trampa 3. Una migración
  que va a producción o cambia funciones existentes (`posicion_fiscal`, rendiciones,
  `calcular_comisiones`, registro de pagos) la hace Opus, según la regla del dueño.
- **Tablas nuevas**:
  - Nacen sin escritura por REST y sin nada para `anon`.
  - La escritura va por RPC `SECURITY DEFINER` que valida el rol y la sucursal adentro.
  - Las RPCs llevan `REVOKE ... FROM PUBLIC, anon`.
  - Cada tabla nace con su policy de SELECT `TO authenticated` según la tabla de roles, o con
    `REVOKE SELECT`; si no, se pone rojo `select_sin_policy`.
  - Si alguna termina escribiéndose por REST: `GRANT USAGE` de la secuencia y
    `scripts/grants-rest.json`.
  - Las funciones de trigger no tienen EXECUTE para nadie.
- **Aislamiento por sucursal**: `sucursal_id NOT NULL` y FKs compuestas `(x_id, sucursal_id)`
  donde corresponda. El empleado "de las dos" y el gasto compartido guardan la sucursal donde se
  cargaron, más su marca.
- **Embeds de PostgREST**: las tablas nuevas tienen varias FKs a `perfiles` (creó, anuló, usuario
  vinculado). Un embed ambiguo rompe la consulta entera (PGRST201). Hay que probar cada embed
  nuevo.
- **Parámetros de RPCs llamadas por PostgREST**: van en `INTEGER`, nunca en `SMALLINT`.
- **Firmas que cambian**: si una RPC cambia de firma, se dropea la vieja (PGRST203). Pasa con
  `confirmar_rendicion` y las de pagos que toquen el adelanto de sueldo. Ojo: las 4 RPCs de pago
  son wrappers, y la lógica vive en `<nombre>_impl` (mig 167).
- **Clientes inactivos**: al vincular la ficha de cliente de un empleado, el buscador decide qué
  hace con los inactivos. Propuesta: mostrarlos, porque el empleado puede tener una ficha vieja.
- **Auditoría**: si se suman checks a `auditoria_integridad()`, hay que mirar qué ids ya están
  tomados. Checks posibles:
  - un pedido congelado en dos liquidaciones vigentes sin ser ajuste;
  - un gasto de rendición que apunta a una rendición inexistente;
  - un movimiento de mercadería que no cuadra con su pago.
- **Corrida completa**: `typecheck`, `lint`, `test:run` sin `.env` y `build`.
- **Lógica pura en `src/utils/` con tests**: prorrateo de sueldo, cuotas del reparto, neto e IVA,
  período semanal o mensual, a pagar.

## 6. Lo que queda para el builder

- Nombres de tablas, columnas, RPCs y hooks.
- En qué grupo del menú van Gastos, Personal y Vehículos (en `TopNavigation`, `guardasRutas`,
  `permisos` y sus tests).
- El diseño de la vista Gastos y de la ficha del vehículo, dentro del estilo de la app y con las
  reglas de arriba.
- Cómo se calcula el saldo: en vivo, cacheado o con una vista.
- Cómo se engancha la auditoría (`audit_logs`) a las tablas nuevas.
- Cómo se parte en PRs. Orden sugerido abajo.

## 7. Orden sugerido

1. **Vehículos, rubros y gastos**: modal, vista, posición fiscal y la expansión por mes.
2. **Rendición**: efectivo a entregar, gastos en el cierre y vista del transportista; se retira
   `rendicion_gastos`.
3. **Personal**: empleados y vínculos, arreglos, cuenta y movimientos automáticos (mercadería y
   reintegros).
4. **Liquidaciones**, con las comisiones congeladas y los ajustes.
5. **Roturas a cargo del empleado**, desde la baja de stock.

## Issues aparte

- **Estado de resultados**, issue #1269: la opción A elegida (una sucursal por vez contra el mes
  anterior, aviso de "antes de confiar en el número", ingresos brutos estimado hasta que se
  cargue). Consume los datos de este módulo.
- **Conexión con el GPS SEMEGA**, issue #1270: km por vehículo y día a la tabla de lecturas.
  Primero hay que pedirle una clave de API al proveedor; si no la da, importar el Excel mensual.
