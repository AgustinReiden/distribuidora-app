// Mensaje de confirmación de `crear_pedido`. Con cargo de envío (#1230) el total
// guardado ya lo incluye: se desglosa "Productos + Envío = Total" para que el
// número no parezca inflado. Sin envío, el mensaje queda como era.

const ars = new Intl.NumberFormat("es-AR", {
  style: "currency",
  currency: "ARS",
  maximumFractionDigits: 0,
});

export function formatPedidoCreado(
  data: { pedido_id: number; total: number; cargo_envio?: number },
): string {
  const total = Number(data.total);
  const envio = Number(data.cargo_envio ?? 0) || 0;
  const cuerpo = envio > 0
    ? `Productos ${ars.format(Math.max(total - envio, 0))} + Envío ${ars.format(envio)} = ${ars.format(total)}`
    : `creado por ${ars.format(total)}`;
  const encabezado = envio > 0
    ? `✅ Pedido #${data.pedido_id} creado.\n${cuerpo}.`
    : `✅ Pedido #${data.pedido_id} ${cuerpo}.`;
  return `${encabezado}\n\n` +
    `Lo podés ver/ajustar en la app web (filtrá por "cargados via bot" si lo querés revisar).`;
}
