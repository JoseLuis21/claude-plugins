---
name: owasp-security
description: Revisa o endurece un servicio backend frente al OWASP Top 10 (2021). Úsala cuando pidan una revisión de seguridad, auditar los endpoints de una API, arreglar una vulnerabilidad concreta (inyección SQL, IDOR, XSS, CSRF, SSRF, deserialización), diseñar autenticación, sesiones o permisos, aceptar subida de archivos, exponer un endpoint nuevo al exterior, o revisar un servicio antes de ponerlo en producción.
---

# OWASP Top 10 en servicios backend

El Top 10 no es una lista de bugs exóticos: son diez sitios donde casi todo servicio se
rompe igual. Esta skill dice dónde mirar en un backend (API HTTP, worker, Lambda), qué
patrón lo arregla y qué "arreglos" son falsos.

Los ejemplos van en Go porque es el stack por defecto de este plugin; el patrón es el
mismo en cualquier lenguaje — cambia la librería, no la decisión.

## Cómo usar esta skill

**Si te piden revisar código existente**: recorre las diez categorías en orden. A01, A03 y
A07 concentran la mayoría de los hallazgos reales en un backend; empieza por ahí si el
tiempo es corto.

**Si te piden escribir código nuevo**: no hace falta el recorrido completo. Mira la tabla
de abajo, localiza qué toca el cambio y aplica solo esas reglas.

| Lo que estás tocando               | Categorías que aplican |
| ---------------------------------- | ---------------------- |
| Endpoint que lee o escribe datos de un usuario | A01, A03 |
| Login, registro, refresh de token, recuperar contraseña | A02, A07 |
| Query, filtro o búsqueda construida con input | A03 |
| Configuración, Dockerfile, variables de entorno | A05 |
| `go.mod`, `package.json`, imagen base | A06 |
| Webhook, integración con URL de terceros, importar desde URL | A10 |
| Subida de archivos | A03, A04, A08 |
| Cualquier cosa que luego alguien tenga que investigar | A09 |

**Regla general al reportar**: di dónde está (`archivo:línea`), qué puede hacer un atacante
con eso en concreto, y el arreglo. Un hallazgo sin escenario de abuso es ruido.

---

## A01 — Broken Access Control

La más común y la más cara. El endpoint autentica ("¿quién eres?") pero no autoriza
("¿te toca este recurso?").

**Cómo se rompe**: el ID del recurso viene del cliente y se usa tal cual.

```go
// MAL: cualquiera con sesión lee la factura de cualquier otro (IDOR)
func (h *Handler) GetInvoice(c *fiber.Ctx) error {
    inv, err := h.repo.FindByID(c.Context(), c.Params("id"))
    ...
}

// BIEN: la propiedad del recurso es parte de la consulta, no un if posterior
func (h *Handler) GetInvoice(c *fiber.Ctx) error {
    userID := auth.UserID(c) // del token verificado, NUNCA del body o de un header
    inv, err := h.repo.FindByIDForUser(c.Context(), c.Params("id"), userID)
    if errors.Is(err, sql.ErrNoRows) {
        return fiber.ErrNotFound // 404, no 403: no confirmes que el recurso existe
    }
    ...
}
```

Reglas:

- **La identidad sale siempre del token verificado en servidor.** Un `X-User-Id` o un
  `user_id` en el body es un campo que el atacante controla.
- **Filtra en la query, no después.** `WHERE id = ? AND tenant_id = ?` no se olvida; un
  `if inv.TenantID != actual` sí, en el siguiente endpoint.
- **Denegar por defecto.** El middleware protege el grupo de rutas entero y las públicas se
  declaran una a una. Al revés, la ruta nueva nace desprotegida.
- **En multi-tenant, el tenant no es un parámetro.** Sale del token y baja por el contexto
  hasta la conexión o el `WHERE`. Si un handler puede elegir tenant, hay fuga.
- **Ojo con los métodos que nadie revisa**: `PATCH`, `DELETE`, los endpoints de export/CSV y
  los de "admin" que se protegieron con "es que esa URL no la sabe nadie".

**Falso arreglo**: ocultar el botón en el frontend. El endpoint sigue ahí.

---

## A02 — Cryptographic Failures

Datos sensibles que viajan o se guardan sin protección, o protegidos con algo roto.

- **Contraseñas**: `bcrypt` (coste ≥ 12) o `argon2id`. Nunca SHA-256, MD5 ni "SHA-256 con
  sal" — son rápidos, que es justo lo que no quieres.
- **Datos sensibles en reposo**: cifra a nivel de campo lo que sea de verdad sensible
  (documento de identidad, cuenta bancaria) con AES-GCM y una clave de KMS/Secrets Manager.
  El cifrado de disco no te protege de un `SELECT`.
- **En tránsito**: TLS en todo, también entre servicios internos. `InsecureSkipVerify: true`
  en un cliente HTTP es un hallazgo, no un detalle de entorno.
- **Aleatoriedad**: tokens, códigos OTP e IDs impredecibles con `crypto/rand`. `math/rand`
  es predecible aunque le pongas semilla con la hora.
- **Comparaciones**: `subtle.ConstantTimeCompare` para tokens y firmas, no `==`.
- **Nunca inventes el esquema.** Si estás escribiendo tu propio cifrado o tu propio formato
  de token, párate y usa uno estándar.

```go
hash, err := bcrypt.GenerateFromPassword([]byte(pw), 12)
token := make([]byte, 32); _, _ = rand.Read(token) // crypto/rand
```

---

## A03 — Injection

Input que deja de ser dato y pasa a ser código, query o comando.

**SQL** — la única regla es que el input nunca se concatena:

```go
// MAL
db.Query("SELECT * FROM users WHERE email = '" + email + "'")

// BIEN
db.QueryContext(ctx, "SELECT * FROM users WHERE email = $1", email)
```

Lo que **no** se puede parametrizar es el nombre de tabla, de columna ni la dirección del
`ORDER BY`. Si el orden o el filtro vienen del cliente, valídalos contra una lista blanca:

```go
var orderable = map[string]string{"fecha": "created_at", "monto": "amount"}
col, ok := orderable[c.Query("sort")]
if !ok { col = "created_at" }
dir := "ASC"; if c.Query("dir") == "desc" { dir = "DESC" }
query := fmt.Sprintf("SELECT ... ORDER BY %s %s", col, dir) // seguro: valores de la lista
```

**NoSQL / MongoDB**: si un valor del body llega a un filtro sin tipar, el cliente puede
mandar `{"$ne": null}` y saltarse la condición. Decodifica a un struct con tipos concretos,
no a `bson.M` ni a `map[string]interface{}`.

**Comandos del sistema**: usa `exec.Command("cmd", arg1, arg2)` con argumentos separados.
En cuanto pasa por `sh -c` con una cadena construida, hay inyección.

**Rutas de archivo**: cualquier nombre que venga del cliente puede traer `../`. Aplica
`filepath.Base` y comprueba que la ruta final sigue dentro del directorio permitido.

**XSS** es inyección también, pero se arregla donde se renderiza: escapa en la plantilla
(`html/template` escapa solo; `text/template` no) y sirve una CSP. Si tu backend solo
devuelve JSON, asegúrate de que el `Content-Type` es `application/json` y de que no estás
reflejando HTML en mensajes de error.

---

## A04 — Insecure Design

Fallos que ninguna librería arregla porque están en la regla de negocio.

Preguntas que hay que hacerse en cada flujo con valor (pago, transferencia, canje, alta):

- **¿Qué pasa si lo llaman dos veces a la vez?** Sin clave de idempotencia o sin bloqueo,
  se cobra dos veces. Las condiciones de carrera en flujos de dinero son el caso clásico.
- **¿Se puede llegar al paso 3 sin pasar por el 2?** Valida el estado en servidor, no
  confíes en el orden en que el frontend llama.
- **¿El precio/importe/descuento viene del cliente?** Recalcúlalo en servidor siempre.
- **¿Cuántas veces por minuto tiene sentido?** Rate limit por usuario y por IP en login,
  OTP, recuperación de contraseña, búsqueda y cualquier endpoint caro.
- **¿Qué límite tiene?** Tamaño de body, tamaño de archivo, número de elementos en un
  array, profundidad del JSON, timeout de la petición. Sin límite hay DoS gratis.

---

## A05 — Security Misconfiguration

- **Nada de credenciales en el código ni en la imagen.** Secrets Manager, SSM o variables
  inyectadas en runtime. Un `.env` copiado en el `Dockerfile` queda en la capa para siempre,
  aunque lo borres en una capa posterior.
- **Errores hacia fuera, genéricos.** El stack trace, la query que falló o la versión del
  driver van al log, no a la respuesta. Devuelve un ID de correlación.
- **CORS explícito.** `AllowOrigins: "*"` junto con `AllowCredentials: true` es una
  combinación inválida además de peligrosa; enumera los orígenes.
- **Apaga lo que no usas**: `pprof`, endpoints de debug, Swagger en producción, `TRACE`.
- **Contenedor**: usuario no-root, imagen base mínima (`distroless`, `alpine`), sin
  compilador ni `curl` en la etapa final. El multi-stage de la skill
  `docker-golang-skills` ya deja la imagen final sin toolchain.
- **Cabeceras**: `Strict-Transport-Security`, `X-Content-Type-Options: nosniff`,
  `Content-Security-Policy` si sirves HTML.

---

## A06 — Vulnerable and Outdated Components

- `govulncheck ./...` en CI — reporta solo las vulnerabilidades cuyo código realmente
  alcanzas, así que el ruido es bajo y merece bloquear el pipeline.
- Fija la imagen base por versión, no por `latest`, y reconstruye periódicamente: la mayoría
  de los CVE de una imagen están en el sistema base, no en tu código.
- Dependabot o Renovate para que la actualización sea un PR y no una tarea que nadie hace.
- Antes de añadir una dependencia para algo trivial: cada una es superficie de ataque y
  alguien que puede publicar código en tu build.

---

## A07 — Identification and Authentication Failures

**Tokens (JWT)** — los tres fallos que se repiten:

1. **No verificar el algoritmo.** Acepta exactamente el que emites; si la librería permite
   `none` o deja que el token elija, un atacante firma lo que quiera.
2. **No verificar `exp`, `iss` y `aud`.** Un token válido de otro entorno o de otra
   aplicación no debe servir aquí.
3. **Confiar en el payload sin validar la firma.** Decodificar no es verificar.

```go
tok, err := jwt.Parse(raw, func(t *jwt.Token) (any, error) {
    if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
        return nil, fmt.Errorf("alg inesperado: %v", t.Header["alg"])
    }
    return secret, nil
}, jwt.WithValidMethods([]string{"HS256"}), jwt.WithIssuer(iss), jwt.WithAudience(aud))
```

**Vida de los tokens**: access corto (minutos) y refresh largo pero revocable y guardado en
servidor. Un JWT de acceso que dura días no se puede echar atrás cuando lo roban.

**Login**:

- Mismo mensaje y tiempo de respuesta para "usuario no existe" y "contraseña incorrecta";
  si no, tienes un enumerador de cuentas.
- Rate limit y bloqueo progresivo por cuenta *y* por IP.
- Rota el identificador de sesión al iniciar sesión y al cambiar de privilegio.
- MFA al menos para cuentas administrativas.

**Recuperar contraseña**: token de un solo uso, con caducidad corta, generado con
`crypto/rand`, invalidado al usarse y al cambiar la contraseña. Y el mismo mensaje de
respuesta exista o no el correo.

---

## A08 — Software and Data Integrity Failures

- **Deserialización**: no deserialices datos que vengan de fuera hacia tipos que ejecutan
  algo al construirse. En Go el riesgo real es más `encoding/gob` y `yaml.Unmarshal` sobre
  estructuras dinámicas que el JSON a un struct tipado.
- **Webhooks**: verifica siempre la firma (HMAC del cuerpo crudo, con comparación en tiempo
  constante) antes de procesar. "Viene de su IP" no es autenticación.
- **Cadena de suministro**: `go.sum` commiteado, acciones de GitHub fijadas por SHA y no por
  tag móvil, imágenes por digest cuando importe.
- **Subida de archivos**: valida el tipo real por contenido y no por extensión ni por el
  `Content-Type` que manda el cliente, renombra el archivo, guárdalo fuera del árbol
  servido, y limita el tamaño antes de leerlo en memoria.

---

## A09 — Security Logging and Monitoring Failures

Sin esto, la brecha existe igual pero te enteras meses después y no puedes reconstruirla.

**Loguea**: login correcto y fallido, cambios de permisos y de contraseña, accesos
denegados (403), operaciones destructivas, y errores 5xx. Con quién, qué, cuándo, desde
dónde y un ID de correlación que atraviese los servicios.

**No loguees nunca**: contraseñas, tokens, cookies de sesión, tarjetas, ni el body completo
de un endpoint de autenticación. Un log con secretos es una filtración con retención.

**Alerta** sobre picos de 401/403, sobre un mismo usuario fallando login desde muchas IPs y
sobre errores 5xx en cadena. Un log que nadie mira no es monitorización.

---

## A10 — Server-Side Request Forgery (SSRF)

Aparece en cuanto el servidor hace una petición a una URL que decide el cliente: importar
desde URL, previsualizar un enlace, avatar remoto, webhook configurable.

El riesgo real está en la nube: desde dentro de la VPC esa URL alcanza el metadata service
(`169.254.169.254`) y los servicios internos que no están expuestos.

```go
// Valida ANTES de pedir, y resuelve el DNS tú mismo:
// el atacante puede apuntar un dominio suyo a una IP privada (DNS rebinding).
ips, err := net.DefaultResolver.LookupIPAddr(ctx, u.Hostname())
for _, ip := range ips {
    if ip.IP.IsLoopback() || ip.IP.IsPrivate() || ip.IP.IsLinkLocalUnicast() {
        return errors.New("destino no permitido")
    }
}
```

Además: solo `http`/`https`, lista blanca de dominios si el caso lo permite, **no sigas
redirecciones automáticamente** (o revalida cada salto), timeout corto y límite de tamaño
de respuesta. Si puedes, saca esas llamadas a una subred sin acceso a la red interna.

---

## Checklist antes de desplegar

- [ ] Todo endpoint no público pasa por el middleware de autenticación, y las excepciones están enumeradas
- [ ] Todo acceso a un recurso filtra por dueño/tenant dentro de la query
- [ ] Ninguna query se construye concatenando input; el orden y los filtros dinámicos van contra lista blanca
- [ ] Contraseñas con bcrypt/argon2; tokens y códigos con `crypto/rand`
- [ ] JWT verificado con algoritmo fijo y con `exp`, `iss`, `aud`
- [ ] Rate limit en login, OTP, recuperación de contraseña y endpoints caros
- [ ] Cero secretos en el repo y en la imagen; todo desde el gestor de secretos
- [ ] Errores hacia fuera sin stack trace ni detalle de infraestructura
- [ ] CORS con orígenes enumerados; contenedor con usuario no-root
- [ ] `govulncheck` en CI, imagen base fijada por versión
- [ ] Límites de tamaño de body, de archivo y timeouts configurados
- [ ] Webhooks con firma verificada en tiempo constante
- [ ] Auditoría de login, 403 y operaciones destructivas — y sin secretos en los logs
- [ ] Toda URL que decide el cliente valida IP resuelta y esquema antes de la petición

## Referencia

Categorías y numeración según el [OWASP Top 10:2021](https://owasp.org/Top10/). Para el
detalle de cada una, las [OWASP Cheat Sheets](https://cheatsheetseries.owasp.org/) son la
fuente a consultar.
