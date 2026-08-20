# Cargos prorrateados y cuadre fiscal de compras

Fecha: 2026-08-18 · Estado: diseño aprobado, pendiente de implementación

## El problema

La carga de compras no sabe representar tres cosas que sí existen en una factura real
(caso testigo: `A0005-00461415` de Manaos, 21 renglones, 13,3 M):

1. **El impuesto interno declarado no coincide con el calculado.** Hoy se cuadra a mano
   con un factor de ajuste (`1,0496` en el caso testigo, casi 5%).
2. **El flete, los pallets y los separadores no tienen dónde ir.** Si se cargan como ítem
   se rompe el stock; si se dejan afuera, el costo unitario queda subvaluado. Y los pallets
   son **no gravados**: sumarlos al costo del producto haría que se les calcule IVA encima.
3. **El reparto de esos cargos no es proporcional al monto sino al volumen** (pallets), y
   algunos aplican sólo a un subconjunto de productos (los separadores, sólo a los bidones).

Magnitud: flete + pallets + separadores son **2.070.800** sobre un costo total sin IVA de
**12.797.344** — el **16,2% del costo**. Hoy ese 16% no está en ningún lado.

## El impuesto interno no es un misterio: es una regla

Reprodujimos el cálculo bucket por bucket. La diferencia no es ruido ni error de alícuota:
**no todas las bonificaciones bajan la base del impuesto interno.**

| Alícuota | II calculado | II declarado | Diferencia |
|---|---:|---:|---:|
| 4,1667 % | 198.231,81 | 199.027,21 | 795,40 |
| 8,6956 % | 322.864,60 | 338.884,46 | 16.019,86 |

Calculando el II sobre la base **sin restar la bonificación "PROMO MANAOS 3000cc"**, pero
**sí restando** la "PROMO COLA 3.00" y el 0,6% general:

| Alícuota | II con base corregida | Declarado | Error |
|---|---:|---:|---:|
| 4,1667 % | 199.027,21 | 199.027,21 | 0,00 |
| 8,6956 % | 338.884,40 | 338.884,46 | 0,06 |

Seis centavos sobre 339 mil. El proveedor trata una promo como **descuento de precio**
(baja la base imponible) y la otra como **bonificación comercial** (no la baja).

### El modelo además corrige al Excel

El factor de ajuste del Excel reparte la diferencia proporcionalmente al II ya calculado
de cada línea, o sea **unta el impuesto interno de la promo sobre productos que no
participaron**. Modelando la causa, cada línea recibe el II de su propia base:

| Línea | II modelo | II Excel | Dif |
|---|---:|---:|---:|
| MANAOS COLA 600cc (sin promo) | 47.983,68 | 50.364,52 | −2.380,84 |
| MANAOS COLA 3000cc (con promo) | 113.961,13 | 112.889,75 | +1.071,38 |
| MANAOS LIMA LIMON 3000cc (con promo) | 14.890,26 | 14.151,42 | +738,85 |

Los totales por alícuota son idénticos al declarado. Cambia **a quién** se le imputa.
Es plata chica por pack (~0,35% del costo) pero es exactamente la contaminación que hace
que un análisis de margen señale al SKU equivocado como rentable.

## Decisiones tomadas

| Tema | Decisión |
|---|---|
| Impuesto interno | Modelar la causa (flag por bonificación) + ajuste residual como red de seguridad |
| Base de prorrateo | Elegible por cargo, con override por línea |
| Flete y descarga | Cada cargo decide por separado si viene en la factura y si prorratea al costo |
| Alcance | Sólo el costo. El análisis de margen y el precio de venta quedan para otra etapa |
| Arquitectura | Cargos persistidos + prorrateo canónico en la RPC; TS sólo para la vista previa |

## Modelo de datos

```sql
compra_cargos
  id, compra_id, orden
  concepto            text          -- "Flete y descarga", "Pallets x 9 tacos"…
  monto               numeric(12,2) -- SIN IVA. Negativo = bonificación
  condicion_iva       text          -- gravado | no_gravado | exento  (mig 177)
  porcentaje_iva      numeric(5,2)
  en_factura          boolean       -- suma al cuadre contra el papel
  prorratea_al_costo  boolean       -- entra al costo unitario
  afecta_base_ii      boolean       -- default: (condicion_iva = 'gravado')
  base_prorrateo      text          -- monto | cantidad | unidades

compra_cargo_repartos
  cargo_id, compra_item_id, peso numeric
```

Dos simplificaciones que salieron del prototipo:

- **El "alcance" no existe como concepto.** Los separadores van 100% al bidón poniendo peso
  `1` en el bidón y `0` en el resto. Alcance = peso cero. Un solo mecanismo.
- **Una bonificación es un cargo de monto negativo.** Misma mecánica; cambia sólo
  `condicion_iva='gravado'` y `afecta_base_ii`. No hacen falta dos entidades.

`base_prorrateo` **sólo pre-llena** el vector de pesos; la verdad siempre es el vector.

Con esto, todo el Excel entra en una sola tabla: flete, pallets, separadores, las dos
promos y hasta el redondeo de −0,49.

## Motor de cálculo

Por línea:

```
neto             = cantidad × costo_unitario × (1 − bonif%)

base_iva_factura = neto + Σ cargos gravados CON en_factura         → compras.iva, cuadre
base_costo       = neto + Σ cargos gravados CON prorratea_al_costo → costo
base_ii          = neto + Σ cargos gravados CON afecta_base_ii
ii               = base_ii × ii% × factor_ajuste[alícuota]
no_grav          = Σ cargos no gravados/exentos CON prorratea_al_costo

costo_real_unitario = (base_costo + ii + no_grav) / cantidad
```

**Las dos bases están separadas a propósito.** Un flete de transportista inscripto viene con
IVA 21%: ese IVA es crédito fiscal, no es costo, y no debe tocar el IVA de esta compra. Su
neto entra al costo; su IVA no entra a ningún lado de esta factura.

`base_iva_factura`, `ii`, `no_grav` e `iva` son exactamente las columnas `Y / Z / AA / AB`
del Excel. **El IVA se calcula sobre `base_iva_factura`, que nunca incluye cargos no
gravados** — que es el bug planteado en el punto 2.

### Factor de ajuste residual

Sólo actúa si se carga el II declarado por alícuota. Con `afecta_base_ii` bien puesto da
`1,000000`. **Si el desvío supera 0,5% el modal avisa** en vez de tapar: deja de ser un
fudge y pasa a ser un detector de alícuota mal cargada.

### Regla de redondeo

Repartir un monto sobre pesos fraccionarios y redondear a 2 decimales no vuelve a sumar el
monto original. Regla fija, idéntica en SQL y TS o el test de espejo no puede pasar:

> Redondear cada reparto a 2 decimales; asignar el residuo a la línea de mayor peso,
> desempatando por menor `compra_item_id`.

## Cambios en funciones existentes

`costo_real_unitario(neto, pct_ii, tipo)` gana un cuarto término aditivo `p_cargo_unitario`.
**Se reemplaza la firma, no se agrega sobrecarga**: dejar la vieja de 3 argumentos junto a
una de 4 con `DEFAULT` reproduce la trampa de la mig 176 (rangos de aridad superpuestos →
ambigüedad invisible para tsc y para los tests). Sus 4 llamadores se actualizan en la misma
migración: `registrar_compra_completa`, `actualizar_compra_items`, `anular_compra_atomica`,
`cambiar_proveedor_compra`.

`actualizar_compra_items` hace `DELETE FROM compra_items`. Con una FK a `compra_item_id` con
`CASCADE`, editar una compra **vaciaría los repartos en silencio**: los cargos quedarían sin
destino, el costo perdería el 16% y `COMPRA-A2` se pondría rojo sin que nadie tocara un
cargo. Por eso la RPC de edición pasa a recibir ítems **y** cargos y reescribe ambos; si
llega sin cargos y la compra tiene, **falla con error explícito**. Un cliente con chunk
viejo editando una compra con cargos es escenario real en este proyecto, no teórico.

`cambiar_proveedor_compra` clona la compra: debe clonar cargos y repartos.

## Qué NO se toca

`compras.total` y `compras.no_gravado` siguen siendo **de la factura**. El flete
(`en_factura=false`) no entra ahí: vive sólo en `compra_cargos` y afecta únicamente
`compra_items.costo_real_unitario` y el costo promedio. Así `COMPRA-A1` sigue en verde y el
cuadre contra el papel no se ensucia.

## Snapshot por línea

`compra_items` agrega `cargos_unitarios numeric(12,4)`. Con sólo `costo_neto_unitario` y
`costo_real_unitario` no se puede reconstruir cuánto fue flete y cuánto impuesto interno al
reabrir la compra.

## Integridad y validaciones

- Check nuevo **`COMPRA-A2`**: Σ repartos de cada cargo = su monto (tolerancia 1 peso).
- Un cargo con `prorratea_al_costo` y Σ pesos = 0 → error al guardar.
- `cantidad = 0` en una línea → guarda contra división por cero (hoy 0 casos en prod).
- RLS en las dos tablas nuevas, espejando la de `compra_items`.

## UX del modal

Sección **"Cargos y prorrateo"**, plegada por defecto. Con 4,1 ítems promedio por compra, la
compra chica ni la ve.

- `+ Agregar cargo` → concepto, monto **sin IVA**, tratamiento, dos casillas (*viene en la
  factura* / *entra al costo*), base de reparto.
- Al elegir base `unidades` se abre una grilla con una celda por línea, pre-llenada.
- **`Traer cargos de la última compra de este proveedor`** — flete y pallets se repiten en
  cada factura de Manaos. Sin esto el reparto manual no es sostenible; con esto, una factura
  nueva es cargar los cargos y ajustar dos números.
- Vista previa por línea con las 4 columnas del Excel + costo unitario final.
- "Control contra factura" se extiende con el II declarado **por alícuota** y su desvío.

## Rollout

Forward-only, como el CPP (migs 127-131): las 63 compras FC existentes no tienen cargos →
`Σ cargos = 0` → costo idéntico al de hoy. **Cero backfill.**

Aviso necesario antes de que aparezca en el dashboard: **el margen reportado de estos
productos va a bajar ~15 puntos.** No es una regresión — es que hasta hoy el 16% del costo
no estaba en ningún lado.

## Limitaciones conocidas (fuera de alcance)

- **Una factura repartida entre sucursales.** La hoja `COMO_INGRESAR_LA_FAC.AL SISTEMA` del
  Excel parte la misma factura entre Taco Pozo y Tucumán. Hoy eso son dos compras distintas,
  así que el monto del cargo que se carga es **el de esa sucursal** y hay que dividirlo a
  mano. Resolverlo de verdad ("una factura = N compras") es un cambio de modelo mayor.
- **Análisis de margen y precio de venta.** Las hojas `AH..AS` y `LISTA PARA PREVENTISTA`
  del Excel. Dependen de que el costo sea confiable primero.
- **Notas de crédito posteriores del proveedor.** Es otro flujo.

## Validación del diseño

Se prototipó el motor completo y se contrastó línea por línea contra el Excel:

- Costo total sin IVA: **12.797.344,26** modelo vs **12.797.344,26** Excel — diferencia 0,00.
- Factor de ajuste residual: **1,000000** en ambas alícuotas (desvío 0,0000%).
- Los totales de II por alícuota coinciden exactamente con los declarados en la factura.

Las diferencias por línea contra el Excel son las esperadas y documentadas arriba: el
modelo imputa el impuesto interno a la base real de cada producto en vez de untarlo.
