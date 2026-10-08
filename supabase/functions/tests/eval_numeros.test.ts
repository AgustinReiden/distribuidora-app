// Tests de la heurística de números inventados y del puntaje de la evaluación
// de modelos (#979). Son funciones puras: no tocan red ni base.

import { assertEquals } from "std/assert/mod.ts";
import { extraerNumeros, numerosInventados } from "../_eval/numeros.ts";
import { argCoincide, evaluarCaso, resolverFecha } from "../_eval/evaluar.ts";
import type { CasoEval } from "../_eval/casos.ts";

Deno.test("extraerNumeros: formatos es-AR", () => {
  assertEquals(extraerNumeros("Vendimos $1.250.130 en total"), [1250130]);
  assertEquals(extraerNumeros("Total 1250130 pesos"), [1250130]);
  assertEquals(extraerNumeros("Son $35.876,22 netos"), [35876.22]);
  assertEquals(extraerNumeros("Subió 12,5% este mes"), [12.5]);
  assertEquals(extraerNumeros("Unas 12% más"), [12]);
});

Deno.test("extraerNumeros: ignora fechas, horas, tamaños y packs", () => {
  assertEquals(extraerNumeros("Entre el 01/09 y el 30/09/2026 (2026-09-30) a las 14:30"), []);
  assertEquals(extraerNumeros("MANAOS COLA 3 LT x 6 a 500 cc o 2,25 LT"), []);
  assertEquals(extraerNumeros("Pack x6, x 12 y 12 x 500cc"), []);
  assertEquals(extraerNumeros("Botella de 3L"), []);
});

Deno.test("extraerNumeros: ignora los menores a 10 y los años sueltos", () => {
  assertEquals(extraerNumeros("Compró 3 veces y 3,5 cajas"), []);
  assertEquals(extraerNumeros("5% de baja"), []);
  assertEquals(extraerNumeros("En 2026 vendimos 120 unidades"), [120]);
});

Deno.test("extraerNumeros: escala M y mil", () => {
  assertEquals(extraerNumeros("Facturó 1,2 M en el mes"), [1_200_000]);
  assertEquals(extraerNumeros("Unos 35 mil pesos"), [35_000]);
});

Deno.test("numerosInventados: respaldado por el resultado, exacto o redondeado", () => {
  const res = [{ total: 1250130.4, ticket: "35876.22", pedidos: 140 }];
  assertEquals(numerosInventados("Vendimos $1.250.130 con ticket de $35.876,22", res), []);
  assertEquals(numerosInventados("Hicimos 140 pedidos", res), []);
});

Deno.test("numerosInventados: marca lo que no está en los resultados", () => {
  const res = [{ total: 1250130 }];
  assertEquals(numerosInventados("Vendimos $1.250.130 y ganamos $999.999", res), [999999]);
});

Deno.test("numerosInventados: escala M dentro del margen de redondeo", () => {
  assertEquals(numerosInventados("Facturó 1,2 M", [{ total: 1234567 }]), []);
  assertEquals(numerosInventados("Facturó 1,9 M", [{ total: 1234567 }]), [1_900_000]);
});

Deno.test("numerosInventados: cantidad de elementos de una lista", () => {
  const res = [{ clientes: Array.from({ length: 25 }, (_, i) => ({ id: i })) }];
  assertEquals(numerosInventados("Son 25 clientes", res), []);
  assertEquals(numerosInventados("Son 26 clientes", res), [26]);
});

Deno.test("numerosInventados: porcentaje de dos valores respaldados", () => {
  const res = [{ vencido: 250000, total: 1000000 }];
  assertEquals(numerosInventados("El 25% está vencido", res), []);
  assertEquals(numerosInventados("El 40% está vencido", res), [40]);
});

Deno.test("resolverFecha: marcadores en fecha local", () => {
  assertEquals(resolverFecha("{hoy}", "2026-10-08"), "2026-10-08");
  assertEquals(resolverFecha("{ayer}", "2026-10-08"), "2026-10-07");
  assertEquals(resolverFecha("{hace30}", "2026-10-08"), "2026-09-08");
  assertEquals(resolverFecha("{inicioMes}", "2026-10-08"), "2026-10-01");
  assertEquals(resolverFecha("{mesPasadoDesde}", "2026-10-08"), "2026-09-01");
  assertEquals(resolverFecha("{mesPasadoHasta}", "2026-10-08"), "2026-09-30");
  assertEquals(resolverFecha("{mesPasadoDesde}", "2026-01-15"), "2025-12-01");
  assertEquals(resolverFecha("manaos", "2026-10-08"), null);
});

Deno.test("argCoincide: contiene, números, booleanos y fechas con margen", () => {
  const hoy = "2026-10-08";
  assertEquals(argCoincide({ contiene: "zingar" }, "Zingará SA", hoy), true);
  assertEquals(argCoincide({ contiene: "zingar" }, undefined, hoy), false);
  assertEquals(argCoincide(5, 5, hoy), true);
  assertEquals(argCoincide(true, "true", hoy), false);
  assertEquals(argCoincide("{hace30}", "2026-09-09", hoy), true);
  assertEquals(argCoincide("{hace30}", "2026-08-01", hoy), false);
  assertEquals(argCoincide("{inicioMes}", "2026-10-02", hoy), false);
});

Deno.test("evaluarCaso: elección, args, prohibidas y repregunta", () => {
  const hoy = "2026-10-08";
  const caso: CasoEval = {
    id: "x",
    rol: "preventista",
    pregunta: "?",
    origen: "escrita",
    herramientas: ["mis_ventas"],
    args: { desde: "{inicioMes}" },
    prohibidas: ["ventas_periodo"],
    debeResponderSinPreguntar: true,
  };
  const bien = evaluarCaso(
    caso,
    "Llevás $1.000.000",
    [{ name: "mis_ventas", args: { desde: "2026-10-01" }, ok: true, data: { total: 1000000 } }],
    hoy,
  );
  assertEquals(bien.ok, true);
  assertEquals(bien.inventados, []);

  const mal = evaluarCaso(
    caso,
    "¿De qué mes?",
    [{ name: "ventas_periodo", args: {}, ok: false }],
    hoy,
  );
  assertEquals(mal.eleccionOk, false);
  assertEquals(mal.prohibidasOk, false);
  assertEquals(mal.sinPreguntaOk, false);
  assertEquals(mal.ok, false);

  const saludo = evaluarCaso(
    { ...caso, args: undefined, prohibidas: undefined, ninguna: true, herramientas: [] },
    "¡Hola!",
    [],
    hoy,
  );
  assertEquals(saludo.ok, true);
});
