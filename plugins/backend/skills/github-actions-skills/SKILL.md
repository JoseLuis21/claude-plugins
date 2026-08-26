---
name: github-actions-skills
description: Escribe, migra o revisa un workflow de GitHub Actions que construye una imagen Docker, la sube a ECR y la despliega en un servicio ECS, en una Lambda de contenedor, o solo publica la imagen. Úsala cuando pidan crear el `.github/workflows/*.yml` de deploy de un microservicio/API/consumer/lambda en AWS, clonar el deploy de otro repo, pasar un deploy a ARM64/Graviton, arreglar un workflow viejo (`::set-output`, sin cache, sin tag por SHA, doble `docker login`), añadir notificaciones a Slack, o inyectar secretos de Secrets Manager en el build.
---

# Deploys a AWS desde GitHub Actions

Un deploy de contenedor a AWS es siempre el mismo esqueleto — checkout, credenciales,
login a ECR, build+push, actualizar el destino, notificar — con tres finales distintos.
Esta skill fija ese esqueleto, dice qué cambia en cada variante y lista los errores que
solo aparecen en producción.

## Elegir plantilla

| Destino                             | Plantilla                   | Señal en el repo                                    |
| ----------------------------------- | --------------------------- | --------------------------------------------------- |
| Servicio ECS (API, front, consumer) | `templates/ecs-service.yml` | hay cluster y task definition                       |
| Lambda como imagen de contenedor    | `templates/lambda.yml`      | `Dockerfile` con base `public.ecr.aws/lambda/...`   |
| Imagen base / solo publicar         | `templates/ecr-image.yml`   | nadie la despliega: otros repos la usan como `FROM` |

Sustituye todo lo que va entre `<...>`. Nada más.

## Antes de escribir: fija las convenciones de la organización

Estos valores no se deducen del código y cambian por empresa. **Sácalos del workflow de un
repo hermano** — el que más se parezca al que estás tocando — y no los inventes:

| Qué                                                            | Dónde mirar                                            |
| -------------------------------------------------------------- | ------------------------------------------------------ |
| Región y cuenta AWS                                            | `env:` de cualquier workflow existente                 |
| Nombre de los secrets de credenciales                          | el paso `configure-aws-credentials`                    |
| Webhook y canales de Slack                                     | los pasos `act10ns/slack`                              |
| Convención de nombres (ECR, cluster, servicio, TD, contenedor) | el `env:` del repo hermano                             |
| Rama que dispara producción                                    | el `on: push:` del repo hermano — no siempre es `main` |

Si no hay repo hermano, pregunta por región, cuenta y nombres de los secrets: son cinco
datos y adivinarlos produce un workflow que falla en el primer push.

## Datos que hay que averiguar del entorno

Cada uno tiene un comando que lo responde. Si no hay credenciales AWS a mano, cópialos del
repo hermano y **dilo explícitamente en el reporte**.

```bash
# Arquitectura real de la task definition (esto decide --platform, no el nombre del cluster)
aws ecs describe-task-definition --task-definition <TD> --region <region> \
  --query 'taskDefinition.{arch:runtimePlatform.cpuArchitecture,containers:containerDefinitions[].name}'

# Nombre exacto del contenedor: un typo aquí da un deploy verde que no cambia nada
aws ecs describe-services --cluster <CLUSTER> --services <SERVICE> --region <region> \
  --query 'services[0].taskDefinition'

# ARN del secreto (lleva sufijo aleatorio: no se puede escribir de memoria)
aws secretsmanager list-secrets --region <region> --query 'SecretList[].[Name,ARN]' --output text

# Arquitectura y entrypoint actuales de la Lambda
aws lambda get-function-configuration --function-name <fn> --region <region> \
  --query '{arch:Architectures,entrypoint:ImageConfigResponse}'
```

## Reglas que no se negocian

- **Etiqueta por SHA además de `latest`.** Publicar solo `:latest` convierte el rollback en
  reconstruir y rezar por que el commit anterior compile igual. Con `:${{ github.sha }}` y
  desplegando por ese tag, el rollback es apuntar a la imagen anterior.
- **`--platform` tiene que coincidir con la task definition.** El cluster no lo decide: un
  mismo cluster puede tener servicios arm64 y amd64. Una imagen amd64 en una TD arm64 arranca
  y muere en bucle con `exec format error`, y `wait-for-service-stability` lo convierte en un
  job colgado diez minutos antes de fallar.
- **QEMU solo si la etapa final del Dockerfile ejecuta algo.** Con Go la etapa builder
  cross-compila (`--platform=$BUILDPLATFORM`) y la final solo copia → `docker/setup-qemu-action`
  sobra y suma minutos. Con Node/TS o PHP, la etapa target sí corre `npm ci` /
  `composer install`: ahí QEMU es obligatorio.
- **`cache-from/to: type=gha, mode=max`.** Es la diferencia entre un deploy de dos minutos y
  uno de ocho, y no cuesta nada. `mode=max` cachea también las capas intermedias del builder,
  que es donde está el trabajo caro.
- **`aws-actions/amazon-ecr-login@v2` ya deja hecho el `docker login`.** Repetir
  `aws ecr get-login-password | docker login` después es ruido heredado de copiar y pegar.
- **La task definition se lee siempre de la familia, sin `:revision`.**
  `describe-task-definition --task-definition <FAMILIA>` devuelve la última ACTIVE, así el
  deploy respeta un cambio de CPU/memoria/rol hecho en la consola en vez de pisarlo.
- **`wait-for-service-stability: true`.** Sin esto el job da verde cuando AWS _acepta_ el
  deploy, no cuando la tarea queda viva: un crash loop pasa desapercibido.
- **Consumers de cola: `minimumHealthyPercent = 0` en el servicio.** Es config del servicio,
  no del workflow, pero sin eso el redeploy solapa dos instancias procesando lo mismo.
- **Lambda: `--provenance=false --sbom=false`, `--architectures` y `wait function-updated`.**
  Lambda rechaza los manifests OCI con las attestations que buildx adjunta por defecto
  (_"The image manifest, config or layer media type ... is not supported"_). Sin
  `--architectures` la función sigue en la arquitectura vieja y la imagen nueva no arranca.
  Sin el `wait`, cualquier `update-function-configuration` posterior falla con
  `ResourceConflictException`.
- **Una Lambda no lleva multi-arch.** Una sola arquitectura: `arm64` (Graviton, ~20% más
  barato) salvo que la función ya sea x86_64 y no se quiera migrar en el mismo PR.
- **`$GITHUB_OUTPUT`, nunca `::set-output`.** Está deprecado desde 2023 y ya avisa en los logs.
- **`concurrency: group: ci-${{ github.ref }}` con `cancel-in-progress`.** Sin eso, dos pushes
  seguidos despliegan en paralelo y gana el que termine último, que no es el más nuevo.
- **`permissions: contents: read`** y un `timeout-minutes` explícito (15 basta; 25 si el job
  compila Go o construye una Lambda).

## Configuración: `.env` horneado vs. secrets de la task definition

Hay dos patrones y conviene no mezclarlos dentro de un mismo equipo.

**A) Bajar el secreto en el workflow y hornearlo en la imagen** (`templates/ecs-service.yml`):

```yaml
- run:
    aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --region "$AWS_REGION" \
    --query 'SecretString' --output text > secrets.json
- run: jq -r 'to_entries|map("\(.key)=\(.value|tostring)")|.[]' secrets.json > "$ENV_FILE"
```

- El Dockerfile hace `COPY .env* /app/` **al final**, para que un cambio de secreto no
  invalide las capas caras de compilación. El glob evita que el build local reviente sin `.env`.
- La task definition queda con `environment: []` y `secrets: []`: no hay que tocarla al desplegar.
- **`.env` no puede estar en `.dockerignore`.** Si alguien lo agrega "por seguridad", el
  contenedor arranca sin configuración y el fallo aparece en runtime, no en el build.
- Nunca imprimas el `.env` en el log; como mucho `wc -l`.
- Coste real: el secreto queda dentro de cada imagen de ECR, así que rotarlo obliga a
  reconstruir y quien pueda hacer `docker pull` del repositorio lo lee.

**B) `secrets:` en la task definition** (`valueFrom` con el ARN): el contenedor recibe las
variables al arrancar, la imagen queda limpia y rotar el secreto no exige rebuild. Es la
opción preferible en verde, pero **cambiar de A a B es un cambio de plataforma para todos los
servicios**: propónlo aparte, nunca colado en un PR de otra cosa.

Si el workflow usa `--region $AWS_DEFAULT_REGION` en ese paso, funciona porque
`configure-aws-credentials` exporta esa variable — pero escribe `$AWS_REGION`, que sí está
declarada en el `env:` del workflow.

## Notificaciones

Dos pasos con `act10ns/slack@v2`, ambos con `if: always()`: uno al principio con
`status: starting` y otro al final con `status: ${{ job.status }}` y
`steps: ${{ toJson(steps) }}`. El mensaje de inicio nombra el servicio concreto — cuando
decenas de repos notifican al mismo canal, "Starting deploy" copiado del vecino no sirve
para nada.

## Auditar un workflow existente

`reference/auditoria.md` tiene los comandos `grep` para detectar cada problema y qué
sustituir en cada caso. Al tocar un repo, arregla de paso lo que aplique y dilo en el PR.

Migrar el tag a SHA cambia el contrato de rollback del equipo (ya no basta con "redeploy de
`latest`"): menciónalo al proponerlo, no lo cueles.

## Verificación antes de dar por hecho el deploy

```bash
# Sintaxis del workflow
actionlint .github/workflows/<archivo>.yml   # o: yq . .github/workflows/<archivo>.yml >/dev/null

# La imagen sale con la arquitectura correcta
docker buildx build --platform linux/arm64 --load -t check:local .
docker image inspect check:local --format '{{.Architecture}}'   # -> arm64

# Post-deploy ECS: la revisión nueva corre y no está reciclando tareas
aws ecs describe-services --cluster <CLUSTER> --services <SERVICE> --region <region> \
  --query 'services[0].{td:taskDefinition,running:runningCount,desired:desiredCount,events:events[0:3].message}'

# Post-deploy Lambda: imagen y arquitectura quedaron como se esperaba
aws lambda get-function-configuration --function-name <fn> --region <region> \
  --query '{arch:Architectures,state:State,update:LastUpdateStatus}'
```

Si no pudiste correr nada de esto (sin credenciales, sin daemon de Docker), dilo tal cual:
un `--platform` equivocado no lo detecta la revisión del YAML, lo detecta producción.
