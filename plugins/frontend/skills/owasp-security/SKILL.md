---
name: owasp-security
description: Revisa o endurece una aplicación web de frontend (React, Next.js, SPA) frente al OWASP Top 10 y a los riesgos propios del navegador. Úsala cuando pidan revisar la seguridad del cliente, prevenir XSS o inyección en el DOM, configurar una CSP o cabeceras de seguridad, decidir dónde guardar el token de sesión, evitar filtrar secretos en el bundle, proteger formularios contra CSRF, revisar Server Actions o route handlers de Next.js, auditar dependencias de npm, o revisar una app antes de sacarla a producción.
---

# OWASP en el frontend

Las mismas diez categorías del Top 10, pero el frontend falla en sitios distintos que el
backend: casi todo se concentra en XSS, en dónde guardas la sesión y en lo que se te escapa
dentro del bundle.

Para la parte de servidor —queries, autorización de servicio, SSRF entre servicios— usa
`/backend:owasp-security`. Esta skill cubre el navegador y la capa de servidor que vive
dentro del framework de frontend (Server Actions, route handlers, middleware).

## La regla que ordena todo lo demás

**El código que corre en el navegador es público y está bajo control del usuario.** No es una
opinión: cualquiera abre las devtools, edita el bundle, quita un `if` y repite la petición con
curl. De ahí salen las tres reglas que no se negocian:

1. **Toda validación del cliente es usabilidad, no seguridad.** Se duplica en servidor. Siempre.
2. **Todo secreto que llegue al bundle está publicado.** No hay forma de ofuscarlo.
3. **Ocultar la UI no protege el endpoint.** Si el botón de admin está escondido pero la ruta
   responde, no hay control de acceso.

## Mapa rápido

| Lo que estás tocando | Dónde suele romperse |
|---|---|
| Renderizar contenido que viene del usuario o de una API | XSS (§1) |
| Login, sesión, refresh de token | Almacenamiento de sesión (§2), CSRF (§4) |
| Variables de entorno, claves de API, feature flags | Secretos en el bundle (§3) |
| Formulario que muta estado, Server Action | CSRF (§4), autorización (§5) |
| Route handler, middleware, `next/image`, proxy | Autorización (§5), SSRF (§7) |
| `package.json`, un paquete nuevo, un script de terceros | Cadena de suministro (§6) |
| Salir a producción | Cabeceras y CSP (§8), checklist final |

---

## 1. XSS — el riesgo número uno del frontend

React escapa por defecto todo lo que interpolas en JSX. El XSS entra por las puertas que se
saltan ese escape, y son pocas y conocidas:

```jsx
// 1. dangerouslySetInnerHTML — el nombre avisa
<div dangerouslySetInnerHTML={{ __html: comentario }} />

// 2. href/src con esquema controlado por el usuario
<a href={urlDelUsuario}>…</a>          // javascript:alert(1) ejecuta al hacer clic

// 3. Escapar de React: refs + innerHTML, document.write, eval, new Function
ref.current.innerHTML = contenido;
```

**Arreglos, en orden de preferencia:**

- **No renderizar HTML.** Si el contenido es texto, trátalo como texto. La mayoría de los
  `dangerouslySetInnerHTML` que hay en producción no necesitaban serlo.
- **Si necesitas HTML enriquecido**, sanitiza con una librería mantenida (DOMPurify) y hazlo
  **al guardar, en servidor**, no solo al pintar: así un consumidor distinto del mismo dato no
  repite el agujero.
- **Valida el esquema de las URLs** antes de ponerlas en `href` o `src`:

```js
const seguro = (u) => {
  try { return ['http:', 'https:', 'mailto:'].includes(new URL(u, location.origin).protocol) }
  catch { return false }
}
```

- **Markdown no es seguro por defecto.** Casi todos los renderizadores permiten HTML embebido
  salvo que lo desactives explícitamente.
- **Una CSP es la red de seguridad**, no el arreglo (§8). Reduce el daño de un XSS que se coló;
  no evita que exista.

Y ojo con el XSS que entra por datos, no por marcado: un objeto de configuración, un nombre de
tema o una traducción que vienen de la API y terminan concatenados en un `style` o en un
atributo.

## 2. Dónde guardar la sesión

La pregunta más común y la que más se responde mal.

| | Cookie `httpOnly` | `localStorage` |
|---|---|---|
| ¿La lee un XSS? | **No** | Sí, en una línea |
| ¿Se envía sola? | Sí → necesita defensa CSRF (§4) | No |
| ¿Sobrevive a recarga? | Sí | Sí |
| Recomendado para | el token de sesión | nada sensible |

**Cookie `httpOnly` + `Secure` + `SameSite=Lax` (o `Strict`) para el token de sesión.** El
argumento de "localStorage evita CSRF" es cierto pero cambia un riesgo por otro peor: CSRF
tiene defensas mecánicas y baratas; un XSS con el token en `localStorage` es una toma de cuenta
completa y silenciosa.

Access token corto y refresh token revocable en servidor. Y no guardes en el cliente datos que
el usuario no debería poder leer: si está en el navegador, es suyo.

## 3. Secretos en el bundle

```
NEXT_PUBLIC_*  →  va al navegador. Cualquier valor ahí es público.
```

El error clásico es poner una clave de servicio en una variable `NEXT_PUBLIC_` "porque la
necesitaba un componente cliente". Si un componente cliente la necesita, el diseño está mal:
la llamada tiene que pasar por una route handler que guarde la clave en servidor.

Antes de desplegar, búscalo en el bundle compilado, no en el código:

```bash
npm run build && grep -rIE '(sk-|AKIA|-----BEGIN|eyJhbGciOi)' .next/static/ | head
```

Y desactiva los **source maps públicos en producción** salvo que los subas a tu herramienta de
errores de forma privada: un source map público devuelve tu código sin minificar, comentarios
incluidos.

## 4. CSRF y clickjacking

**CSRF.** Aplica a todo lo que mute estado y se autentique con cookie. Las defensas, de menos a
más trabajo:

1. `SameSite=Lax` en la cookie de sesión — cubre la mayoría de los casos y es una línea.
2. Token anti-CSRF por formulario si necesitas `SameSite=None` (flujos entre dominios).
3. Comprobar `Origin` en el servidor en las peticiones que mutan.

En Next.js las **Server Actions traen protección CSRF de origen**, pero eso no las autoriza:
sigue siendo tu trabajo comprobar quién es el usuario dentro de la acción (§5).

**Clickjacking.** `X-Frame-Options: DENY`, o mejor `frame-ancestors 'none'` en la CSP. Si tu app
se embebe legítimamente, enumera los orígenes en vez de abrirlo.

## 5. Autorización: el frontend no autoriza

Ocultar el botón está bien para la experiencia y no vale nada como control.

- **Cada Server Action y cada route handler comprueba sesión y permiso**, aunque solo se invoque
  desde una pantalla ya protegida. Una Server Action es un endpoint HTTP público con otro nombre.
- **El middleware es un filtro, no la autorización.** Sirve para redirigir a login; no sustituye
  la comprobación dentro del handler, porque no todas las rutas pasan por él y su matcher se
  desactualiza.
- **No confíes en un id que venga del cliente.** El usuario sale del token en servidor, y el
  recurso se filtra por dueño dentro de la consulta.
- **Cuidado con lo que cruza de servidor a cliente.** Todo lo que le pasas como prop a un
  componente cliente viaja serializado al navegador: si le pasas el objeto de usuario entero, el
  hash de la contraseña y el correo interno van dentro. Selecciona los campos.

## 6. Dependencias y terceros

El frontend tiene la cadena de suministro más expuesta que existe: cientos de paquetes
transitivos que ejecutan scripts en tu build y código en el navegador de tus usuarios.

- `npm audit --omit=dev` en CI, y una revisión periódica que alguien firme.
- **Lockfile commiteado y `npm ci`** en CI, nunca `npm install`.
- Antes de añadir un paquete: descargas, fecha del último commit, cuántas dependencias
  transitivas arrastra. Para algo trivial, escríbelo.
- **Los scripts de terceros** (analítica, chat, píxeles) corren con todos tus privilegios en la
  página. Cárgalos con `next/script` y la estrategia correcta, limita cuáles permite tu CSP, y
  usa **SRI** (`integrity`) cuando el proveedor publique el hash.
- Un `<iframe>` de terceros va con `sandbox` y los permisos mínimos.

## 7. SSRF y proxies del frontend

Aparece en cuanto tu route handler pide una URL que decide el cliente: previsualizar un enlace,
importar desde una URL, un avatar remoto, un proxy de imágenes.

Desde el servidor esa URL alcanza la red interna y el metadata service del proveedor cloud.
Valida **antes** de pedir: solo `http`/`https`, resuelve el DNS y rechaza IPs privadas o de
loopback, no sigas redirecciones automáticamente, y pon timeout y límite de tamaño.

Caso concreto de Next.js: `images.remotePatterns` con `**` convierte el optimizador de imágenes
en un proxy abierto. Enumera los dominios.

## 8. Cabeceras y CSP

Mínimo para producción:

```
Content-Security-Policy: default-src 'self'; frame-ancestors 'none'; object-src 'none'; base-uri 'self'
Strict-Transport-Security: max-age=63072000; includeSubDomains
X-Content-Type-Options: nosniff
Referrer-Policy: strict-origin-when-cross-origin
Permissions-Policy: camera=(), microphone=(), geolocation=()
```

Dos avisos sobre la CSP que ahorran una tarde:

- **`unsafe-inline` en `script-src` anula la mitad del beneficio.** Si el framework necesita
  scripts inline, usa nonces por petición en vez de abrirlo.
- **Despliégala primero en `Content-Security-Policy-Report-Only`** y mira los informes unos
  días. Una CSP estricta activada de golpe rompe la app en producción, y la reacción típica es
  desactivarla entera.

CORS es del servidor, no del navegador: `Access-Control-Allow-Origin: *` junto con credenciales
es inválido además de peligroso. Enumera los orígenes.

## Checklist antes de salir a producción

- [ ] Cero `dangerouslySetInnerHTML` sin sanitizar; los que queden, justificados y con la
      sanitización en el punto de guardado
- [ ] Esquema validado en toda `href`/`src` que venga de datos
- [ ] Token de sesión en cookie `httpOnly` + `Secure` + `SameSite`; nada sensible en `localStorage`
- [ ] `grep` de secretos sobre el bundle compilado, no sobre el código
- [ ] Source maps de producción no públicos
- [ ] Cada Server Action y route handler comprueba sesión **y** permiso por su cuenta
- [ ] Los props que cruzan a componentes cliente llevan solo los campos necesarios
- [ ] Validación de cliente duplicada en servidor, sin excepciones
- [ ] CSP desplegada (probada antes en Report-Only) + HSTS + `nosniff` + `frame-ancestors`
- [ ] `npm ci` con lockfile; `npm audit` en CI; scripts de terceros con SRI y en la lista de la CSP
- [ ] `images.remotePatterns` y cualquier proxy con dominios enumerados
- [ ] Errores hacia el usuario sin stack trace ni detalle de infraestructura

## Referencia

Categorías según el [OWASP Top 10:2021](https://owasp.org/Top10/). Para el detalle por tema, las
[OWASP Cheat Sheets](https://cheatsheetseries.owasp.org/) — en particular XSS Prevention,
Content Security Policy y CSRF Prevention.
