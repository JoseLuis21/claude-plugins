# Auditoría de un workflow de deploy

Comandos para pasarle a un repo (o a todos los de una organización) antes de tocarlo.
Cada bloque detecta un problema y dice con qué sustituirlo. Corre esto desde la raíz del
repo, o cambia `.github/workflows` por `*/.github/workflows` para barrer varios clones.

## 1. Sintaxis deprecada

```bash
grep -rln '::set-output' .github/workflows
```
→ `echo "image=..." >> $GITHUB_OUTPUT`. Deprecado desde 2023; ya avisa en los logs.

```bash
grep -rn 'configure-aws-credentials@v[123]\|checkout@v[123]\|amazon-ecr-login@v1' .github/workflows
```
→ `configure-aws-credentials@v4`, `checkout@v4`, `amazon-ecr-login@v2`. Las versiones
viejas corren sobre runtimes de Node ya retirados por GitHub.

## 2. Sin `concurrency`

```bash
grep -rLn 'concurrency' .github/workflows/*.yml
```
→ añadir arriba del `env:`:
```yaml
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
```
Sin esto, dos pushes seguidos despliegan en paralelo y gana el que termine último, que no
es necesariamente el más nuevo.

## 3. Build sin cache

```bash
grep -rLn 'type=gha' .github/workflows/*.yml          # workflows sin cache
grep -rn 'docker build ' .github/workflows            # build plano, sin buildx
```
→ `docker/build-push-action@v6` con `cache-from: type=gha` y `cache-to: type=gha,mode=max`,
o `docker buildx build --cache-from type=gha --cache-to type=gha,mode=max`.

## 4. `docker login` duplicado

```bash
grep -rn 'get-login-password' .github/workflows
```
→ borrar el paso: `aws-actions/amazon-ecr-login@v2` ya deja la sesión abierta.

## 5. Solo tag `:latest` (sin rollback)

```bash
grep -rLn 'github.sha' .github/workflows/*.yml
```
→ publicar `:${{ github.sha }}` **además** de `:latest`, y desplegar por el tag de SHA.
Ojo: esto cambia el contrato de rollback del equipo — ya no basta con "redeploy de
`latest`". Menciónalo al proponerlo.

## 6. Arquitectura

```bash
grep -rn 'platform' .github/workflows                 # qué arquitectura construye
aws ecs describe-task-definition --task-definition <TD> --region <region> \
  --query 'taskDefinition.runtimePlatform'            # cuál espera el destino
```
→ tienen que coincidir. El nombre del cluster **no** impone la arquitectura: la fija el
`runtimePlatform` de cada task definition, y un mismo cluster puede mezclar arm64 y amd64.
Un workflow sin `--platform` construye lo que sea el runner (amd64).

```bash
grep -rn 'setup-qemu' .github/workflows
```
→ QEMU solo si la etapa final del Dockerfile ejecuta algo (`npm ci`, `composer install`).
En repos Go que cross-compilan con `--platform=$BUILDPLATFORM`, sobra: son minutos regalados.

## 7. Lambdas

```bash
grep -rn 'update-function-code' .github/workflows
```
Para cada resultado, verifica que el workflow tenga las tres cosas:
- `--provenance=false --sbom=false` en el build (Lambda rechaza los manifests OCI con
  attestations: *"The image manifest, config or layer media type ... is not supported"*).
- `--architectures <arm64|x86_64>` en `update-function-code` (sin eso la función se queda en
  la arquitectura vieja y la imagen nueva no arranca).
- `aws lambda wait function-updated` después (sin eso, cualquier
  `update-function-configuration` posterior falla con `ResourceConflictException`).

## 8. Deploy que da verde sin desplegar

```bash
grep -rLn 'wait-for-service-stability' .github/workflows/*.yml
grep -rn 'CONTAINER_NAME\|container-name' .github/workflows
```
→ `wait-for-service-stability: true` hace que el job falle si la tarea entra en crash loop.
Y el `container-name` debe ser idéntico al de la task definition: si no coincide, el render
no reemplaza la imagen, el deploy sale verde y no cambia nada. Verifícalo con
`aws ecs describe-task-definition --query 'taskDefinition.containerDefinitions[].name'`.

## 9. Incoherencias que solo se ven mirando varios repos a la vez

Vale la pena revisarlas de a una, no automatizarlas: casi siempre hay una razón histórica
detrás, y "arreglarlas" sin preguntar rompe algo.

- Dos workflows sobre la misma rama apuntando al mismo servicio (corren en paralelo).
- La rama que despliega producción no es la que sugiere su nombre (`development` → prod).
- El nombre de los recursos AWS no coincide con el del repo (repo `...-stage3` desplegando
  recursos `...STAGE2`).
- Task definition y contenedor con el mismo nombre: válido, pero confunde al copiarlo.
- Mismo repositorio ECR compartido por dos entornos distinguidos solo por el tag
  (`latest` para dev, `production` para prod): un push a la rama equivocada pisa el otro.

Para levantar la foto completa de una organización:

```bash
for f in */.github/workflows/*.yml; do
  printf '%-60s %s\n' "$f" "$(grep -hE 'ECR_REPOSITORY:|ECS_CLUSTER:|ECS_SERVICE:|LAMBDA_ARN:' "$f" | tr -d ' ' | paste -sd' ' -)"
done
```
