# Supabase Edge Functions

Funciones serverless en Deno que corren en el edge de Supabase.

Actualmente: `telegram-webhook` (Fase 1.2 — sin LLM todavía).

## Variables de entorno

Las edge functions reciben estas variables de Supabase. Las dos primeras se
inyectan automáticamente cuando la función está desplegada en Supabase; las
otras dos hay que setearlas explícitamente como secrets.

| Variable                      | Origen                          | Descripción                                          |
| ----------------------------- | ------------------------------- | ---------------------------------------------------- |
| `SUPABASE_URL`                | Auto-inyectada por Supabase     | URL del proyecto                                     |
| `SUPABASE_SERVICE_ROLE_KEY`   | Auto-inyectada por Supabase     | Key con permisos elevados                            |
| `TELEGRAM_BOT_TOKEN`          | Setear como secret              | Token del bot (BotFather)                            |
| `TELEGRAM_WEBHOOK_SECRET`     | Setear como secret              | String random único, validado en cada request        |
| `GEMINI_API_KEY`              | Setear como secret (Phase 3+)   | API key de Google AI Studio para function calling    |
| `GEMINI_MODEL`                | Opcional (default abajo)        | Override del modelo. Default: `gemini-2.5-flash`     |
| `BOT_MAX_TOOL_ITERATIONS`     | Opcional (default 5, rango 1-20)| Cap del loop de tool-calls del agente Gemini         |

Setear secrets en producción:

```bash
supabase secrets set TELEGRAM_BOT_TOKEN=123:ABC
supabase secrets set TELEGRAM_WEBHOOK_SECRET=$(openssl rand -hex 32)
supabase secrets set GEMINI_API_KEY=AIzaSy...   # https://aistudio.google.com/apikey
```

### Sobre `GEMINI_MODEL`

El default es `gemini-2.5-flash` (estable, GA). Es configurable via env var
para poder bumpear el modelo sin re-deploy. Hoy NO usamos `gemini-3-flash-preview`
porque tiene un bug activo con `thought_signature` en parallel function calls.
Cuando Gemini 3 sea estable (estimado Q3 2026), se puede actualizar el secret:

```bash
supabase secrets set GEMINI_MODEL=gemini-3-flash
```

Para desarrollo local crear un `.env.local` (ya en `.gitignore`):

```ini
TELEGRAM_BOT_TOKEN=123:ABC
TELEGRAM_WEBHOOK_SECRET=mi-secret-de-dev
SUPABASE_URL=https://localhost:54321
SUPABASE_SERVICE_ROLE_KEY=eyJ... # del comando `supabase status`
```

## Levantar localmente

```bash
# desde la raíz del repo
supabase functions serve telegram-webhook \
  --env-file supabase/functions/.env.local \
  --no-verify-jwt
```

`--no-verify-jwt` es necesario porque Telegram no manda JWT — autenticamos con
`TELEGRAM_WEBHOOK_SECRET`.

## Configurar el webhook de Telegram

Una vez desplegada la función a producción:

```bash
TOKEN="<TELEGRAM_BOT_TOKEN>"
SECRET="<TELEGRAM_WEBHOOK_SECRET>"
URL="https://<project-ref>.supabase.co/functions/v1/telegram-webhook"

curl -s "https://api.telegram.org/bot${TOKEN}/setWebhook" \
  -H "Content-Type: application/json" \
  -d "{
    \"url\": \"${URL}\",
    \"secret_token\": \"${SECRET}\",
    \"drop_pending_updates\": true,
    \"allowed_updates\": [\"message\"]
  }"
```

Para verificar:

```bash
curl -s "https://api.telegram.org/bot${TOKEN}/getWebhookInfo" | jq
```

## Probar localmente con curl

Ejemplo `/start`:

```bash
curl -i -X POST http://localhost:54321/functions/v1/telegram-webhook \
  -H "Content-Type: application/json" \
  -H "X-Telegram-Bot-Api-Secret-Token: mi-secret-de-dev" \
  -d '{
    "update_id": 1,
    "message": {
      "message_id": 1,
      "date": 1700000000,
      "chat": { "id": 999, "type": "private" },
      "from": { "id": 999, "is_bot": false, "first_name": "Tito" },
      "text": "/start"
    }
  }'
```

Ejemplo `/vincular ABC123` (requiere que primero hayas generado el código
desde la app web con `generar_codigo_vinculacion_bot`):

```bash
curl -i -X POST http://localhost:54321/functions/v1/telegram-webhook \
  -H "Content-Type: application/json" \
  -H "X-Telegram-Bot-Api-Secret-Token: mi-secret-de-dev" \
  -d '{
    "update_id": 2,
    "message": {
      "message_id": 2,
      "date": 1700000000,
      "chat": { "id": 999, "type": "private" },
      "from": { "id": 999, "is_bot": false, "first_name": "Tito", "username": "tito" },
      "text": "/vincular ABC123"
    }
  }'
```

Sin secret:

```bash
curl -i -X POST http://localhost:54321/functions/v1/telegram-webhook \
  -d '{}'
# → 403 forbidden
```

## Tests

Desde `supabase/functions/`:

```bash
deno task test
```

Equivalente:

```bash
deno test --allow-env --allow-net=api.telegram.org
```

Los tests usan mocks de `fetch` y un cliente Supabase falso (no requieren
red ni base de datos).

## Type-check sin correr

```bash
deno task check
```

## Lint y format

```bash
deno task lint
deno task fmt
```

## Deploy

```bash
supabase functions deploy telegram-webhook
```

(Asegurate de tener `supabase link --project-ref <ref>` antes.)

## Estructura del código

```
supabase/functions/
├── _shared/
│   ├── audit.ts        # logEvent → bot_audit_log (fail-closed)
│   ├── auth.ts         # resolveUserByTelegramId, canjearCodigo (RPC)
│   ├── supabase.ts     # singleton del cliente service_role
│   ├── telegram.ts     # sendMessage, escapeMarkdownV2, parseUpdate
│   ├── types.ts        # tipos de la Telegram Bot API + dominio del bot
│   ├── tools/          # Tool registry + tools por rol (Phase 2)
│   └── gemini/         # Cliente Gemini, schema mapper, system prompts (Phase 3)
│       ├── client.ts
│       ├── schema.ts
│       ├── types.ts
│       └── prompts/    # admin.txt, preventista.txt, transportista.txt, ...
├── telegram-webhook/
│   ├── commands/       # parser + router de slash commands
│   ├── formatters/     # respuestas → texto Telegram
│   ├── handlers.ts     # /start, /ayuda, /vincular
│   └── index.ts        # entrypoint, validación de secret, error handling
├── tests/
│   ├── telegram-webhook.test.ts
│   ├── tools.test.ts
│   └── gemini.test.ts
├── .gitignore
├── deno.json
└── README.md           (este archivo)
```

## Privacidad y retención

- `bot_audit_log` registra cada mensaje recibido (`texto_usuario`) y cada respuesta del bot (`texto_bot`) en plaintext, con `perfil_id` y `telegram_user_id`. Esto es necesario para debugging y compliance interno.
- Retención: cron mensual (migration 016) borra rows con `created_at < now() - interval '90 days'`.
- `bot_conversaciones.mensajes` mantiene los últimos 12 turnos por chat para contexto del LLM. Truncado automático.
- El comando `/start` informa al usuario que sus mensajes quedan registrados 90 días — alineado con esta política.
- Si el negocio requiere mayor restricción (ej: GDPR, sector regulado), considerar redactar partes del prompt/respuesta antes de logear.
