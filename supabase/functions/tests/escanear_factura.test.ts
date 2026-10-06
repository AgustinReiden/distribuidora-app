// Tests de escanear-factura (sin red): matriz de auth, guarda de ruta y
// sucursal, cuentas de validación con facturas sintéticas y el handler con
// Gemini y storage mockeados.
import { assert, assertEquals, assertFalse } from "std/assert/mod.ts";
import {
  type AutorizarEscaneoDeps,
  autorizarEscaneo,
  type PerfilEscaneo,
  type SucursalDelUsuario,
} from "../escanear-factura/auth.ts";
import { detectarMime, MAX_BYTES_FACTURA, validarRutaFactura } from "../escanear-factura/ruta.ts";
import {
  aBase64,
  construirPedidoGemini,
  leerRespuestaGemini,
  MODELO_FACTURA_DEFAULT,
  modeloFactura,
} from "../escanear-factura/extraccion.ts";
import {
  normalizarCuit,
  normalizarFactura,
  normalizarFecha,
  parseNumeroAR,
  tipoFacturaApp,
} from "../escanear-factura/validacion.ts";
import { crearCors, crearHandler, type EscanearDeps } from "../escanear-factura/handler.ts";
import type {
  GeminiGenerateContentRequest,
  GeminiGenerateContentResponse,
  GeminiInlineDataPart,
} from "../_shared/gemini/types.ts";

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

const UUID = "0b7c1d2e-3f40-4a5b-8c6d-7e8f9a0b1c2d";

function depsAuth(opts: {
  usuario?: { id: string } | null;
  perfil?: PerfilEscaneo | null;
  sucursales?: SucursalDelUsuario[];
}): AutorizarEscaneoDeps {
  return {
    obtenerUsuario: () => Promise.resolve(opts.usuario === undefined ? { id: "u1" } : opts.usuario),
    obtenerPerfil: () => Promise.resolve(opts.perfil === undefined ? { rol: "encargado", activo: true } : opts.perfil),
    obtenerSucursales: () =>
      Promise.resolve(opts.sucursales ?? [{ sucursal_id: 1, es_default: true, rol: "mismo" }]),
  };
}

function req(headers: Record<string, string> = { Authorization: "Bearer x" }, body: unknown = { path: `1/${UUID}.jpg` }) {
  return new Request("https://fn.local/escanear-factura", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
}

Deno.test("auth: sin Authorization → 401", async () => {
  const r = await autorizarEscaneo(req({}), depsAuth({}));
  assertEquals(r.ok ? 200 : r.status, 401);
});

Deno.test("auth: token inválido → 401", async () => {
  const r = await autorizarEscaneo(req(), depsAuth({ usuario: null }));
  assertEquals(r.ok ? 200 : r.status, 401);
});

Deno.test("auth: sin perfil o perfil dado de baja → 403", async () => {
  for (const perfil of [null, { rol: "admin", activo: false }]) {
    const r = await autorizarEscaneo(req(), depsAuth({ perfil }));
    assertEquals(r.ok ? 200 : r.status, 403);
  }
});

Deno.test("auth: matriz de roles (sólo admin y encargado escanean)", async () => {
  const casos: Array<[string, boolean]> = [
    ["admin", true],
    ["encargado", true],
    ["preventista", false],
    ["transportista", false],
    ["deposito", false],
  ];
  for (const [rol, permitido] of casos) {
    const r = await autorizarEscaneo(req(), depsAuth({ perfil: { rol, activo: true } }));
    assertEquals(r.ok, permitido, `rol ${rol}`);
  }
});

Deno.test("auth: el rol propio de la sucursal pisa el del perfil", async () => {
  // admin en el perfil pero preventista en esta sucursal → no.
  const a = await autorizarEscaneo(
    req(),
    depsAuth({ perfil: { rol: "admin", activo: true }, sucursales: [{ sucursal_id: 1, es_default: true, rol: "preventista" }] }),
  );
  assertFalse(a.ok);
  // preventista en el perfil pero encargado en esta sucursal → sí.
  const b = await autorizarEscaneo(
    req(),
    depsAuth({ perfil: { rol: "preventista", activo: true }, sucursales: [{ sucursal_id: 1, es_default: true, rol: "encargado" }] }),
  );
  assert(b.ok);
  if (b.ok) assertEquals(b.rol, "encargado");
});

Deno.test("auth: X-Sucursal-ID de una sucursal ajena → 403; mal formado → 400", async () => {
  const ajena = await autorizarEscaneo(req({ Authorization: "Bearer x", "X-Sucursal-ID": "2" }), depsAuth({}));
  assertEquals(ajena.ok ? 200 : ajena.status, 403);
  const mal = await autorizarEscaneo(req({ Authorization: "Bearer x", "X-Sucursal-ID": "1;drop" }), depsAuth({}));
  assertEquals(mal.ok ? 200 : mal.status, 400);
});

Deno.test("auth: resuelve la sucursal del header y, sin header, la default", async () => {
  const sucursales = [
    { sucursal_id: 1, es_default: true, rol: "mismo" },
    { sucursal_id: 7, es_default: false, rol: null },
  ];
  const conHeader = await autorizarEscaneo(req({ Authorization: "Bearer x", "X-Sucursal-ID": "7" }), depsAuth({ sucursales }));
  assert(conHeader.ok);
  if (conHeader.ok) assertEquals(conHeader.sucursalId, 7);
  const sinHeader = await autorizarEscaneo(req(), depsAuth({ sucursales }));
  assert(sinHeader.ok);
  if (sinHeader.ok) assertEquals(sinHeader.sucursalId, 1);
  const sinSucursal = await autorizarEscaneo(req(), depsAuth({ sucursales: [] }));
  assertEquals(sinSucursal.ok ? 200 : sinSucursal.status, 403);
});

// ---------------------------------------------------------------------------
// Ruta y sucursal
// ---------------------------------------------------------------------------

Deno.test("ruta: acepta <sucursal>/<uuid>.<ext> de la sucursal activa", () => {
  for (const ext of ["jpg", "jpeg", "png", "webp", "heic", "pdf"]) {
    assert(validarRutaFactura(`3/${UUID}.${ext}`, 3).ok, ext);
  }
});

Deno.test("ruta: otra sucursal → 403", () => {
  const r = validarRutaFactura(`4/${UUID}.jpg`, 3);
  assertEquals(r.ok ? 200 : r.status, 403);
});

Deno.test("ruta: formas inválidas → 400", () => {
  const malas: unknown[] = [
    undefined,
    "",
    42,
    `facturas/3/${UUID}.jpg`,
    `3/../4/${UUID}.jpg`,
    `../3/${UUID}.jpg`,
    `3/${UUID}.JPG`,
    `3/${UUID}.exe`,
    `3/factura.jpg`,
    `3/${UUID}.jpg/extra`,
    `facturas/1700000000_foto.jpg`,
    `/3/${UUID}.jpg`,
  ];
  for (const p of malas) {
    const r = validarRutaFactura(p, 3);
    assertEquals(r.ok ? 200 : r.status, 400, String(p));
  }
});

Deno.test("detectarMime: por los bytes, no por la extensión", () => {
  const enc = new TextEncoder();
  assertEquals(detectarMime(enc.encode("%PDF-1.7 ...")), "application/pdf");
  assertEquals(detectarMime(new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0])), "image/jpeg");
  assertEquals(detectarMime(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])), "image/png");
  assertEquals(detectarMime(enc.encode("RIFF\0\0\0\0WEBPVP8 ")), "image/webp");
  assertEquals(detectarMime(enc.encode("\0\0\0\x18ftypheic\0\0")), "image/heic");
  assertEquals(detectarMime(enc.encode("MZ\x90\0 ejecutable")), null);
  assertEquals(detectarMime(new Uint8Array([])), null);
});

// ---------------------------------------------------------------------------
// Parsers
// ---------------------------------------------------------------------------

Deno.test("parseNumeroAR: formatos argentinos", () => {
  assertEquals(parseNumeroAR(1234.56), 1234.56);
  assertEquals(parseNumeroAR("1.234,56"), 1234.56);
  assertEquals(parseNumeroAR("$ 1.234.567,8"), 1234567.8);
  assertEquals(parseNumeroAR("12,5"), 12.5);
  assertEquals(parseNumeroAR("1.234"), 1234);
  assertEquals(parseNumeroAR("10.5"), 10.5);
  assertEquals(parseNumeroAR("1,234.56"), 1234.56);
  assertEquals(parseNumeroAR("-3.000,00"), -3000);
  assertEquals(parseNumeroAR("(500)"), -500);
  assertEquals(parseNumeroAR("abc"), null);
  assertEquals(parseNumeroAR(""), null);
  assertEquals(parseNumeroAR(null), null);
  assertEquals(parseNumeroAR(Number.NaN), null);
});

Deno.test("normalizarCuit: formatea y valida el dígito verificador sin corregirlo", () => {
  assertEquals(normalizarCuit("20123456786"), { cuit: "20-12345678-6", valido: true, crudo: "20123456786" });
  assertEquals(normalizarCuit("30-71234567-1").valido, true);
  const mal = normalizarCuit("20-12345678-5");
  assertEquals(mal.cuit, "20-12345678-5");
  assertEquals(mal.valido, false);
  assertEquals(normalizarCuit("123").cuit, null);
  assertEquals(normalizarCuit(null).cuit, null);
});

Deno.test("normalizarFecha", () => {
  assertEquals(normalizarFecha("2026-09-30"), "2026-09-30");
  assertEquals(normalizarFecha("30/09/2026"), "2026-09-30");
  assertEquals(normalizarFecha("1/9/26"), "2026-09-01");
  assertEquals(normalizarFecha("31/02/2026"), null);
  assertEquals(normalizarFecha("ayer"), null);
});

Deno.test("tipoFacturaApp: A, B, C y M→FC (la letra viaja en tipoComprobante); remito→ZZ; otro→null", () => {
  assertEquals(tipoFacturaApp("A"), "FC");
  assertEquals(tipoFacturaApp("B"), "FC");
  assertEquals(tipoFacturaApp("C"), "FC");
  assertEquals(tipoFacturaApp("M"), "FC");
  assertEquals(tipoFacturaApp("remito"), "ZZ");
  assertEquals(tipoFacturaApp("otro"), null);
});

// ---------------------------------------------------------------------------
// Validación con facturas sintéticas
// ---------------------------------------------------------------------------

/**
 * Factura A que cierra: dos alícuotas, un descuento al pie que baja la base de
 * IVA en proporción, II y percepciones.
 *   L1: 10 × 1000 − 10% = 9000 (21%)   L2: 5 × 200 = 1000 (10,5%)
 *   Desc. pie 500 → neto gravado 9500 (factor 0,95)
 *   IVA 21% = 8550 × 0,21 = 1795,50 · IVA 10,5% = 950 × 0,105 = 99,75
 *   Total = 9500 + 1795,50 + 99,75 + 300 + 150 + 200 = 12045,25
 */
function facturaA(): Record<string, unknown> {
  return {
    tipoComprobante: "A",
    puntoVenta: "5",
    numero: "455160",
    fechaEmision: "30/09/2026",
    proveedor: { nombre: "Refres Now SA", cuit: "30712345671" },
    condicionVenta: "Cuenta corriente",
    items: [
      {
        codigo: "MC3000",
        descripcion: "MANAOS COLA 3000CC X6",
        cantidad: 10,
        unidad: "bulto",
        unidadesPorBulto: 6,
        precioUnitarioNeto: 1000,
        bonificacionPct: 10,
        importeNeto: 9000,
        alicuotaIva: 21,
        impuestoInternoMonto: null,
        legible: true,
      },
      {
        codigo: null,
        descripcion: "GALLETITAS X 12",
        cantidad: 5,
        unidad: "bulto",
        unidadesPorBulto: 12,
        precioUnitarioNeto: "200,00",
        bonificacionPct: 0,
        importeNeto: "1.000,00",
        alicuotaIva: 10.5,
        impuestoInternoMonto: null,
        legible: true,
      },
    ],
    pie: {
      netoGravado: 9500,
      noGravado: null,
      exento: null,
      iva: [{ alicuota: 21, monto: 1795.5 }, { alicuota: 10.5, monto: 99.75 }],
      impuestosInternos: [{ tasa: 8.6956, monto: 300 }],
      percepcionIva: 150,
      percepcionIibb: 200,
      otrosTributos: null,
      descuentosPie: [{ descripcion: "Bonif. promo 3000cc", monto: -500 }],
      total: 12045.25,
    },
    confianza: 0.93,
  };
}

const errores = (adv: { nivel: string }[]) => adv.filter((a) => a.nivel === "error");
const codigos = (adv: { codigo: string }[]) => adv.map((a) => a.codigo);

Deno.test("validación: una factura A que cierra no da errores y normaliza el formato", () => {
  const { data, advertencias } = normalizarFactura(facturaA());
  assertEquals(errores(advertencias), []);
  assertEquals(data.version, 2);
  assertEquals(data.tipoFactura, "FC");
  assertEquals(data.numeroCompleto, "0005-00455160");
  assertEquals(data.fechaEmision, "2026-09-30");
  assertEquals(data.proveedor.cuit, "30-71234567-1");
  assertEquals(data.items[1].precioUnitarioNeto, 200);
  assertEquals(data.items[1].importeNeto, 1000);
  assertEquals(data.items[0].bonificacionPct, 10);
  assertEquals(data.pie.descuentosPie, [{ descripcion: "Bonif. promo 3000cc", monto: 500 }]);
});

Deno.test("validación: una línea que no cuadra se avisa con su número y NO se corrige", () => {
  const f = facturaA();
  (f.items as Array<Record<string, unknown>>)[0].importeNeto = 9800; // debería ser 9000
  const { data, advertencias } = normalizarFactura(f);
  const linea = advertencias.find((a) => a.codigo === "LINEA_NO_CUADRA");
  assert(linea, "falta LINEA_NO_CUADRA");
  assertEquals(linea.linea, 1);
  assertEquals(linea.nivel, "error");
  assertEquals(data.items[0].importeNeto, 9800, "el importe leído no se toca");
});

Deno.test("validación: Σ líneas vs neto (una línea faltante)", () => {
  const f = facturaA();
  (f.items as unknown[]).pop();
  const { advertencias } = normalizarFactura(f);
  assert(codigos(advertencias).includes("SUMA_LINEAS_NO_CUADRA"));
});

Deno.test("validación: descuento al pie que ya estaba restado en las líneas → aviso, no error", () => {
  const f = facturaA();
  const pie = f.pie as Record<string, unknown>;
  pie.netoGravado = 10000;
  pie.iva = [{ alicuota: 21, monto: 1890 }, { alicuota: 10.5, monto: 105 }];
  pie.total = 10000 + 1890 + 105 + 300 + 150 + 200;
  const { advertencias } = normalizarFactura(f);
  assert(codigos(advertencias).includes("DESCUENTOS_PIE_NO_RESTADOS"));
  assertFalse(codigos(advertencias).includes("SUMA_LINEAS_NO_CUADRA"));
});

Deno.test("validación: IVA de una alícuota que no corresponde a su base", () => {
  const f = facturaA();
  (f.pie as Record<string, unknown>).iva = [{ alicuota: 21, monto: 2100 }, { alicuota: 10.5, monto: 99.75 }];
  const { advertencias } = normalizarFactura(f);
  const iva = advertencias.filter((a) => a.codigo === "IVA_NO_CUADRA");
  assertEquals(iva.length, 1);
  assert(iva[0].mensaje.includes("21%"));
});

Deno.test("validación: total distinto de la suma de las partes", () => {
  const f = facturaA();
  (f.pie as Record<string, unknown>).total = 13045.25;
  const { advertencias } = normalizarFactura(f);
  assert(codigos(advertencias).includes("TOTAL_NO_CUADRA"));
});

Deno.test("validación: la tolerancia absorbe el redondeo de centavos", () => {
  const f = facturaA();
  (f.pie as Record<string, unknown>).total = 12045.9; // 65 centavos de diferencia
  (f.items as Array<Record<string, unknown>>)[0].importeNeto = 9000.4;
  const { advertencias } = normalizarFactura(f);
  assertEquals(errores(advertencias), []);
});

Deno.test("validación: bonificación es porcentaje — fuera de 0..100 es error", () => {
  const f = facturaA();
  (f.items as Array<Record<string, unknown>>)[0].bonificacionPct = 150;
  const { advertencias } = normalizarFactura(f);
  assert(codigos(advertencias).includes("BONIFICACION_FUERA_DE_RANGO"));
});

Deno.test("validación: remito sin pie desglosado → ZZ y sólo se chequea el total", () => {
  const { data, advertencias } = normalizarFactura({
    tipoComprobante: "remito",
    puntoVenta: null,
    numero: "1234",
    fechaEmision: "2026-10-01",
    proveedor: { nombre: "Distribuidora X", cuit: null },
    condicionVenta: "Contado",
    items: [
      { codigo: null, descripcion: "AGUA 2L", cantidad: 3, unidad: null, unidadesPorBulto: null, precioUnitarioNeto: 500, bonificacionPct: 0, importeNeto: 1500, alicuotaIva: null, impuestoInternoMonto: null, legible: true },
    ],
    pie: { netoGravado: null, noGravado: null, exento: null, iva: [], impuestosInternos: [], percepcionIva: null, percepcionIibb: null, otrosTributos: null, descuentosPie: [], total: 1500 },
    confianza: 0.9,
  });
  assertEquals(data.tipoFactura, "ZZ");
  assertEquals(data.numeroCompleto, "00001234");
  assertEquals(errores(advertencias), []);
});

Deno.test("validación: línea ilegible, confianza baja, B → avisos", () => {
  const f = facturaA();
  f.tipoComprobante = "B";
  f.confianza = 0.3;
  (f.items as Array<Record<string, unknown>>)[1].legible = false;
  const { data, advertencias } = normalizarFactura(f);
  // mig 293: una B es una factura (FC); la letra la deja en "costo = lo pagado".
  assertEquals(data.tipoFactura, "FC");
  assertEquals(data.tipoComprobante, "B");
  const c = codigos(advertencias);
  assert(c.includes("LINEA_ILEGIBLE"));
  assert(c.includes("CONFIANZA_BAJA"));
  assert(c.includes("FACTURA_SIN_IVA_DISCRIMINADO"));
  assertEquals(advertencias.find((a) => a.codigo === "LINEA_ILEGIBLE")?.linea, 2);
});

Deno.test("validación: basura del modelo no tira — queda todo en null con avisos", () => {
  const { data, advertencias } = normalizarFactura("no soy un objeto");
  assertEquals(data.items, []);
  assertEquals(data.pie.total, null);
  assertEquals(data.tipoFactura, null);
  assert(codigos(advertencias).includes("SIN_LINEAS"));
});

// ---------------------------------------------------------------------------
// Pedido y respuesta de Gemini
// ---------------------------------------------------------------------------

Deno.test("construirPedidoGemini: structured output, temperatura 0, media inline", () => {
  const p = construirPedidoGemini("QUJD", "application/pdf");
  assertEquals(p.generationConfig?.temperature, 0);
  assertEquals(p.generationConfig?.responseMimeType, "application/json");
  assert(p.generationConfig?.responseSchema);
  const media = p.contents[0].parts[0] as GeminiInlineDataPart;
  assertEquals(media.inlineData, { mimeType: "application/pdf", data: "QUJD" });
});

Deno.test("modeloFactura: env o default", () => {
  assertEquals(modeloFactura(() => undefined), MODELO_FACTURA_DEFAULT);
  assertEquals(modeloFactura(() => "  "), MODELO_FACTURA_DEFAULT);
  assertEquals(modeloFactura(() => "gemini-x"), "gemini-x");
});

Deno.test("leerRespuestaGemini: JSON, JSON con fence, cortada y bloqueada", () => {
  const conTexto = (text: string, finishReason = "STOP"): GeminiGenerateContentResponse => ({
    candidates: [{ content: { role: "model", parts: [{ text }] }, finishReason }],
  });
  assertEquals(leerRespuestaGemini(conTexto('{"a":1}')), { ok: true, json: { a: 1 } });
  assertEquals(leerRespuestaGemini(conTexto('```json\n{"a":1}\n```')), { ok: true, json: { a: 1 } });
  const cortada = leerRespuestaGemini(conTexto('{"a":', "MAX_TOKENS"));
  assertEquals(cortada.ok ? "" : cortada.motivo, "cortada");
  const bloqueada = leerRespuestaGemini({ promptFeedback: { blockReason: "SAFETY" } });
  assertEquals(bloqueada.ok ? "" : bloqueada.motivo, "bloqueada");
  const invalida = leerRespuestaGemini(conTexto("no json"));
  assertEquals(invalida.ok ? "" : invalida.motivo, "json_invalido");
});

Deno.test("aBase64: igual que btoa, también con archivos grandes", () => {
  const bytes = new Uint8Array(100_000).map((_, i) => i % 256);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  assertEquals(aBase64(bytes), btoa(bin));
});

// ---------------------------------------------------------------------------
// Handler (Gemini y storage mockeados)
// ---------------------------------------------------------------------------

const PDF = new TextEncoder().encode("%PDF-1.7\n...contenido...");
const RESPUESTA_OK: GeminiGenerateContentResponse = {
  candidates: [{ content: { role: "model", parts: [{ text: JSON.stringify(facturaA()) }] }, finishReason: "STOP" }],
};

function depsHandler(over: Partial<EscanearDeps> = {}) {
  const llamadas = { descargar: [] as string[], generar: [] as GeminiGenerateContentRequest[] };
  const deps: EscanearDeps = {
    autorizar: () => Promise.resolve({ ok: true, userId: "u1", rol: "encargado", sucursalId: 1 }),
    descargar: (objeto) => {
      llamadas.descargar.push(objeto);
      return Promise.resolve(PDF);
    },
    generar: (pedido) => {
      llamadas.generar.push(pedido);
      return Promise.resolve(RESPUESTA_OK);
    },
    geminiConfigurado: true,
    modelo: "gemini-test",
    cors: crearCors(undefined),
    ...over,
  };
  return { deps, llamadas };
}

async function invocar(deps: EscanearDeps, body: unknown = { path: `1/${UUID}.pdf` }, method = "POST") {
  const res = await crearHandler(deps)(
    new Request("https://fn.local/escanear-factura", {
      method,
      headers: { Authorization: "Bearer x", "Content-Type": "application/json" },
      body: method === "POST" ? JSON.stringify(body) : undefined,
    }),
  );
  const text = await res.text();
  return { status: res.status, text, json: text.startsWith("{") ? JSON.parse(text) : null, headers: res.headers };
}

Deno.test("handler: camino feliz con un PDF → success, data v2, advertencias y modelo", async () => {
  const { deps, llamadas } = depsHandler();
  const r = await invocar(deps);
  assertEquals(r.status, 200);
  assertEquals(r.json.success, true);
  assertEquals(r.json.modelo, "gemini-test");
  assertEquals(r.json.data.version, 2);
  assertEquals(r.json.data.tipoFactura, "FC");
  assert(Array.isArray(r.json.advertencias));
  assertEquals(llamadas.descargar, [`1/${UUID}.pdf`]);
  const media = llamadas.generar[0].contents[0].parts[0] as GeminiInlineDataPart;
  assertEquals(media.inlineData.mimeType, "application/pdf");
  assertEquals(media.inlineData.data, aBase64(PDF));
});

Deno.test("handler: OPTIONS responde CORS; GET → 405", async () => {
  const { deps } = depsHandler();
  const pre = await crearHandler(deps)(new Request("https://fn.local/x", { method: "OPTIONS" }));
  assertEquals(pre.status, 200);
  assert(pre.headers.get("Access-Control-Allow-Headers")?.includes("x-sucursal-id"));
  await pre.text();
  const get = await invocar(deps, undefined, "GET");
  assertEquals(get.status, 405);
});

Deno.test("handler: sin autorización corta antes de descargar o llamar a Gemini", async () => {
  const { deps, llamadas } = depsHandler({
    autorizar: () => Promise.resolve({ ok: false, status: 403, mensaje: "Escanear facturas es sólo para admin o encargado." }),
  });
  const r = await invocar(deps);
  assertEquals(r.status, 403);
  assertEquals(r.json.success, false);
  assertEquals(llamadas.descargar.length + llamadas.generar.length, 0);
});

Deno.test("handler: archivo de otra sucursal → 403 sin descargar", async () => {
  const { deps, llamadas } = depsHandler();
  const r = await invocar(deps, { path: `2/${UUID}.pdf` });
  assertEquals(r.status, 403);
  assertEquals(llamadas.descargar.length, 0);
});

Deno.test("handler: body sin path → 400", async () => {
  const { deps } = depsHandler();
  assertEquals((await invocar(deps, {})).status, 400);
});

Deno.test("handler: archivo inexistente 404, vacío 400, grande 413, tipo raro 415", async () => {
  assertEquals((await invocar(depsHandler({ descargar: () => Promise.resolve(null) }).deps)).status, 404);
  assertEquals((await invocar(depsHandler({ descargar: () => Promise.resolve(new Uint8Array()) }).deps)).status, 400);
  const grande = new Uint8Array(MAX_BYTES_FACTURA + 1);
  grande.set(PDF);
  assertEquals((await invocar(depsHandler({ descargar: () => Promise.resolve(grande) }).deps)).status, 413);
  const exe = new TextEncoder().encode("MZ\x90\0");
  const { deps, llamadas } = depsHandler({ descargar: () => Promise.resolve(exe) });
  assertEquals((await invocar(deps)).status, 415);
  assertEquals(llamadas.generar.length, 0);
});

Deno.test("handler: sin GEMINI_API_KEY → 503 sin descargar", async () => {
  const original = console.error;
  console.error = () => {};
  try {
    const { deps, llamadas } = depsHandler({ geminiConfigurado: false });
    const r = await invocar(deps);
    assertEquals(r.status, 503);
    assertEquals(llamadas.descargar.length, 0);
  } finally {
    console.error = original;
  }
});

Deno.test("handler: falla de Gemini → 502 sin filtrar el detalle al cliente", async () => {
  const original = console.error;
  console.error = () => {};
  try {
    const { deps } = depsHandler({
      generar: () => Promise.reject(new Error("Gemini 400: API key AIzaSyFAKE-SECRETO not valid")),
    });
    const r = await invocar(deps);
    assertEquals(r.status, 502);
    assertFalse(r.text.includes("AIza"));
    assertFalse(r.text.includes("Gemini 400"));
  } finally {
    console.error = original;
  }
});

Deno.test("handler: respuesta sin factura reconocible → 422", async () => {
  const original = console.error;
  console.error = () => {};
  try {
    const vacia: GeminiGenerateContentResponse = {
      candidates: [{ content: { role: "model", parts: [{ text: '{"items":[],"pie":{"total":null}}' }] }, finishReason: "STOP" }],
    };
    const r = await invocar(depsHandler({ generar: () => Promise.resolve(vacia) }).deps);
    assertEquals(r.status, 422);
  } finally {
    console.error = original;
  }
});

Deno.test("crearCors: APP_ORIGIN con varios orígenes devuelve el del request si está", () => {
  const cors = crearCors("https://app.ejemplo.com, https://staging.ejemplo.com");
  const de = (origin: string) => new Request("https://fn.local", { headers: { Origin: origin } });
  assertEquals(cors(de("https://staging.ejemplo.com"))["Access-Control-Allow-Origin"], "https://staging.ejemplo.com");
  assertEquals(cors(de("https://malo.com"))["Access-Control-Allow-Origin"], "https://app.ejemplo.com");
  assertEquals(crearCors(undefined)(de("https://x.com"))["Access-Control-Allow-Origin"], "*");
});

Deno.test("validación: la M se reconoce como factura M (FC), sin aviso de IVA no discriminado", () => {
  const f = facturaA();
  f.tipoComprobante = "m";
  const { data, advertencias } = normalizarFactura(f);
  assertEquals(data.tipoComprobante, "M");
  assertEquals(data.tipoFactura, "FC");
  assert(!codigos(advertencias).includes("FACTURA_SIN_IVA_DISCRIMINADO"));
  assert(!codigos(advertencias).includes("TIPO_DESCONOCIDO"));
});
