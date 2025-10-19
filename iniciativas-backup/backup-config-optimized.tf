# ============================================================================
# CONFIGURACIÓN OPTIMIZADA - SISTEMA DE BACKUP S3
# ============================================================================
# Este archivo contiene la configuración centralizada para el sistema de
# backups S3 con routing automático basado en frecuencias.
#
# CARACTERÍSTICAS:
# - Routing automático: < 24h usa event-driven, ≥ 24h usa manifest diff
# - Mapeo de criticidad por frecuencia
# - Storage classes y retenciones GFS mantenidas
# - Variables configurables en un solo lugar
# ============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# VARIABLES DE FRECUENCIA (Configurables)
# ─────────────────────────────────────────────────────────────────────────────

variable "backup_frequencies" {
  description = <<-EOT
    Frecuencias de backup configurables (en horas).
    El sistema determina automáticamente:
    - Si frecuencia < 24h → Usa incremental_backup (event-driven)
    - Si frecuencia >= 24h → Usa filter_inventory (manifest diff)
    
    Mapeo automático de criticidad:
    - 1h - 12h → Crítico
    - 12h - 24h → Menos Crítico  
    - > 24h → No Crítico (sin incrementales automáticos)
  EOT

  type = object({
    critical_hours      = number # Default: 4, 6, 12
    less_critical_hours = number # Default: 12, 18, 24
    non_critical_hours  = number # Default: 168 (7 días), solo full
  })

  default = {
    critical_hours      = 12  # Cada 12 horas (event-driven)
    less_critical_hours = 24  # Cada 24 horas (event-driven o manifest diff)
    non_critical_hours  = 168 # Cada 7 días (solo full, sin incrementales)
  }

  validation {
    condition = (
      var.backup_frequencies.critical_hours >= 1 &&
      var.backup_frequencies.critical_hours <= 12 &&
      var.backup_frequencies.less_critical_hours >= 12 &&
      var.backup_frequencies.less_critical_hours <= 24
    )
    error_message = "Crítico: 1-12h, Menos Crítico: 12-24h, No Crítico: >24h"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# LÓGICA DE ROUTING AUTOMÁTICO
# ─────────────────────────────────────────────────────────────────────────────

locals {
  # Determinar método de backup por criticidad
  backup_methods = {
    Critico      = var.backup_frequencies.critical_hours < 24 ? "event_driven" : "manifest_diff"
    MenosCritico = var.backup_frequencies.less_critical_hours < 24 ? "event_driven" : "manifest_diff"
    NoCritico    = "manifest_diff" # Siempre manifest diff para full schedules
  }

  # Expresiones de schedule basadas en frecuencias configurables
  schedule_expressions_computed = {
    Critico = {
      incremental = var.backup_frequencies.critical_hours < 24 ? "rate(${var.backup_frequencies.critical_hours} hours)" : null
      sweep       = "rate(7 days)"      # Full semanal
      grandfather = "cron(0 3 1 * ? *)" # Mensual
    }

    MenosCritico = {
      incremental = var.backup_frequencies.less_critical_hours < 24 ? "rate(${var.backup_frequencies.less_critical_hours} hours)" : null
      sweep       = "rate(14 days)"       # Full quincenal
      grandfather = "cron(0 3 1 */3 ? *)" # Trimestral
    }

    NoCritico = {
      # Sin incrementales para ahorrar costos
      incremental = null
      sweep       = "rate(${var.backup_frequencies.non_critical_hours} hours)"
      grandfather = null # Sin grandfather
    }
  }

  # Storage classes por criticidad (mantenidas como están)
  storage_classes = {
    Critico      = "GLACIER_IR"
    MenosCritico = "GLACIER_IR"
    NoCritico    = "GLACIER"
  }

  # Retenciones GFS por criticidad (mantenidas)
  gfs_retentions = {
    Critico = {
      son_days            = 14  # 2 semanas incrementales
      father_days         = 365 # 1 año full
      grandfather_days    = 730 # 2 años auditoría
      father_da_days      = 90  # Transición a DEEP_ARCHIVE
      grandfather_da_days = 0   # Inmediato a DEEP_ARCHIVE
    }

    MenosCritico = {
      son_days            = 7   # 1 semana incrementales
      father_days         = 120 # 4 meses full
      grandfather_days    = 365 # 1 año auditoría
      father_da_days      = 90
      grandfather_da_days = 0
    }

    NoCritico = {
      son_days            = 0  # Sin incrementales
      father_days         = 90 # Mínimo GLACIER
      grandfather_days    = 0  # Sin grandfather
      father_da_days      = 0
      grandfather_da_days = 0
    }
  }

  # Información de routing para debugging
  routing_info = {
    for criticality, method in local.backup_methods : criticality => {
      method = method
      frequency_hours = (
        criticality == "Critico" ? var.backup_frequencies.critical_hours :
        criticality == "MenosCritico" ? var.backup_frequencies.less_critical_hours :
        var.backup_frequencies.non_critical_hours
      )
      uses_event_driven   = method == "event_driven"
      uses_manifest_diff  = method == "manifest_diff"
      incremental_enabled = local.schedule_expressions_computed[criticality].incremental != null
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# OUTPUT: INFORMACIÓN DE CONFIGURACIÓN
# ─────────────────────────────────────────────────────────────────────────────

output "backup_configuration_summary" {
  description = "Resumen de la configuración de backups"
  value = {
    frequencies = {
      critical_hours      = var.backup_frequencies.critical_hours
      less_critical_hours = var.backup_frequencies.less_critical_hours
      non_critical_hours  = var.backup_frequencies.non_critical_hours
    }

    routing = local.routing_info

    schedules = {
      for criticality, schedules in local.schedule_expressions_computed :
      criticality => {
        incremental_schedule = schedules.incremental
        sweep_schedule       = schedules.sweep
        grandfather_schedule = schedules.grandfather
        backup_method        = local.backup_methods[criticality]
      }
    }

    storage_classes = local.storage_classes

    retentions = {
      for criticality, retention in local.gfs_retentions :
      criticality => {
        incremental_days = retention.son_days
        full_days        = retention.father_days
        audit_days       = retention.grandfather_days
      }
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# EJEMPLOS DE USO
# ─────────────────────────────────────────────────────────────────────────────

# EJEMPLO 1: Cambiar frecuencia crítica de 12h a 6h (todo se adapta automáticamente)
#
# backup_frequencies = {
#   critical_hours      = 6   # ← Cambio aquí
#   less_critical_hours = 24
#   non_critical_hours  = 168
# }
# 
# RESULTADO AUTOMÁTICO:
# - Schedule: rate(6 hours)
# - Método: event_driven (porque 6 < 24)
# - Storage: GLACIER_IR
# - Retención: 14 días incrementales

# EJEMPLO 2: Cambiar menos crítico a 30h (pasa a manifest diff)
#
# backup_frequencies = {
#   critical_hours      = 12
#   less_critical_hours = 30  # ← Cambio aquí (>24h)
#   non_critical_hours  = 168
# }
#
# RESULTADO AUTOMÁTICO:
# - Schedule: rate(30 hours)
# - Método: manifest_diff (porque 30 >= 24)
# - Usa filter_inventory con checkpoint
# - Storage: GLACIER_IR
# - Retención: 7 días incrementales

# EJEMPLO 3: Cambiar no crítico de 7 días a 30 días
#
# backup_frequencies = {
#   critical_hours      = 12
#   less_critical_hours = 24
#   non_critical_hours  = 720  # ← 30 días en horas
# }
#
# RESULTADO AUTOMÁTICO:
# - Schedule: rate(720 hours)
# - Método: manifest_diff (solo full)
# - Sin incrementales
# - Storage: GLACIER
# - Retención: 90 días

# ─────────────────────────────────────────────────────────────────────────────
# DIAGRAMA DE DECISIÓN
# ─────────────────────────────────────────────────────────────────────────────

/*
┌─────────────────────────────────────────────────────────────────────────┐
│                    SISTEMA DE ROUTING AUTOMÁTICO                        │
└─────────────────────────────────────────────────────────────────────────┘

                        Usuario configura frecuencia
                                    │
                                    ▼
              ┌─────────────────────────────────────────┐
              │   ¿Frecuencia < 24 horas?               │
              └─────────────────────────────────────────┘
                     │                           │
                     │ SÍ                        │ NO
                     ▼                           ▼
        ┌────────────────────────┐    ┌──────────────────────────┐
        │  METHOD: EVENT_DRIVEN  │    │  METHOD: MANIFEST_DIFF   │
        │                        │    │                          │
        │  Trigger:              │    │  Trigger:                │
        │  ├─ S3 Events → SQS    │    │  └─ EventBridge Scheduler│
        │  └─ Lambda: incremental│    │                          │
        │     _backup            │    │  Process:                │
        │                        │    │  ├─ filter_inventory     │
        │  Features:             │    │  ├─ Compare checkpoint   │
        │  ├─ Real-time (minutos)│    │  └─ Generate manifest    │
        │  ├─ Window aggregation │    │                          │
        │  └─ High frequency OK  │    │  Features:               │
        │                        │    │  ├─ Inventory-based      │
        │  Best for:             │    │  ├─ Efficient at scale   │
        │  └─ 1-23 hours RPO     │    │  └─ Lower API costs      │
        │                        │    │                          │
        │  Storage: GLACIER_IR   │    │  Best for:               │
        │  Retention: 7-14 days  │    │  └─ ≥24 hours RPO        │
        └────────────────────────┘    │                          │
                                      │  Storage: GLACIER_IR/    │
                                      │           GLACIER        │
                                      │  Retention: Variable     │
                                      └──────────────────────────┘
                     │                           │
                     └───────────┬───────────────┘
                                 │
                                 ▼
                    ┌────────────────────────────┐
                    │  S3 Batch Operations       │
                    │  Copy to Central Bucket    │
                    │                            │
                    │  Path: backup/             │
                    │    criticality=X/          │
                    │    backup_type=incremental/│
                    │    generation=son/         │
                    └────────────────────────────┘
                                 │
                                 ▼
                    ┌────────────────────────────┐
                    │  Lifecycle Policies (GFS)  │
                    │                            │
                    │  Son → Father → Grandfather│
                    │  GLACIER_IR → DEEP_ARCHIVE │
                    └────────────────────────────┘

MAPEO DE CRITICIDAD POR FRECUENCIA:
┌──────────────────┬─────────────┬──────────────┬─────────────┐
│ Frecuencia       │ Criticidad  │ Método       │ Storage     │
├──────────────────┼─────────────┼──────────────┼─────────────┤
│ 1h - 12h         │ Crítico     │ Event-Driven │ GLACIER_IR  │
│ 12h - 24h        │ Menos Crít. │ Event-Driven │ GLACIER_IR  │
│ > 24h            │ No Crítico  │ Manifest Diff│ GLACIER     │
└──────────────────┴─────────────┴──────────────┴─────────────┘

*/
