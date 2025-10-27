# Simple Backup Restore App

Esta aplicación independiente ofrece una forma visual y sencilla de restaurar copias de seguridad
almacenadas en buckets de Amazon S3 **sin versionado**, gestionando hasta diez cuentas AWS desde
una única interfaz.

## Características clave

- 🔐 Administración centralizada de hasta 10 cuentas AWS mediante asunción de roles (STS).
- 🪣 Compatibilidad con buckets S3 sin versionado y estructura de carpetas por servicio/entorno.
- ♻️ Restauración guiada en tres pasos (selección de cuenta, selección de respaldo, destino).
- 🖥️ Interfaz web ligera basada en FastAPI + Jinja2.
- 🧩 Arquitectura modular para personalizar estrategias de restauración (descarga local o copia a
  otro bucket/prefijo).

## Estructura del proyecto

```
simple-backup-app/
├── app/
│   ├── __init__.py
│   ├── config.py
│   ├── dependencies.py
│   ├── main.py
│   ├── models.py
│   ├── s3_service.py
│   └── views.py
├── config/
│   └── accounts.example.yaml
├── requirements.txt
├── README.md
├── static/
│   └── styles.css
└── templates/
    ├── account_detail.html
    ├── base.html
    └── index.html
```

## Prerrequisitos

1. Python 3.11+
2. Credenciales con permisos para asumir los roles definidos para cada cuenta hija
3. Los buckets S3 destino deben existir y **no tener versionado habilitado**

## Configuración

1. Copia `config/accounts.example.yaml` a `config/accounts.yaml` y actualiza las entradas para cada
   cuenta:

```yaml
default_restore_strategy: copy
accounts:
  - id: "111111111111"
    name: "Cuenta Producción"
    role_arn: "arn:aws:iam::111111111111:role/BackupOperator"
    region: "us-east-1"
    backup_bucket: "prod-backups"
    backup_prefix: "snapshots/"
    restore_bucket: "prod-restore"
    restore_prefix: "pending/"
```

- `backup_bucket` y `backup_prefix`: origen de los respaldos (sin versionado)
- `restore_bucket` y `restore_prefix`: destino estándar para restauraciones automatizadas
- `default_restore_strategy`: `copy` (copia en S3) o `download` (descarga a la máquina local)

2. Si necesitas gestionar menos de diez cuentas, elimina las entradas no utilizadas.
3. Si el archivo `accounts.yaml` no existe, la aplicación cargará los datos de ejemplo para que la
   interfaz se renderice correctamente, aunque sin realizar acciones reales.

## Uso

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp config/accounts.example.yaml config/accounts.yaml  # personaliza el contenido
uvicorn app.main:app --reload
```

Accede a `http://localhost:8000` y sigue el asistente visual:

1. Selecciona la cuenta AWS.
2. Explora los respaldos disponibles dentro del bucket S3 sin versionado.
3. Elige la acción de restauración (copiar a destino estándar o descargar).

El backend registrará cada restauración en memoria (en un futuro se puede guardar en DynamoDB).

## Personalización

- Modifica `app/s3_service.py` para adaptar la lógica de restauración (por ejemplo, copiar a EFS,
  iniciar un proceso de Glue, etc.).
- Añade autenticación a la interfaz integrando Amazon Cognito o un proveedor SSO.
- Implementa auditoría persistente en `app/models.py` guardando los eventos en DynamoDB o RDS.

## Despliegue multi-cuenta

Cada cuenta AWS puede desplegarse de forma independiente ejecutando la misma aplicación con su
propio archivo `accounts.yaml`. El proyecto actual no comparte componentes entre cuentas; simplemente
se puede duplicar e instalar en cada cuenta que opere el servicio de copias de seguridad.

## Próximos pasos sugeridos

1. **Contenerización**: crear un `Dockerfile` y desplegar la app en AWS App Runner o ECS Fargate.
2. **Autenticación**: integrar un flujo SSO para operadores.
3. **Auditoría**: guardar un historial de restauraciones en DynamoDB con TTL.
4. **Notificaciones**: enviar avisos de restauración por SNS o Slack.

