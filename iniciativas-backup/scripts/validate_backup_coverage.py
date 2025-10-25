#!/usr/bin/env python3
"""
Valida cobertura de backups: compara objetos en origen vs central.

Uso:
    python scripts/validate_backup_coverage.py \\
        --source-bucket dev-raw-data \\
        --central-bucket 00-dev-central-bcks-mvp \\
        --criticality Critico \\
        --region eu-west-1 \\
        --profile dev

    # Validar todos los buckets etiquetados
    python scripts/validate_backup_coverage.py \\
        --central-bucket 00-dev-central-bcks-mvp \\
        --region eu-west-1 \\
        --all-tagged

Salida:
    - 0: Cobertura completa (100%)
    - 1: Cobertura parcial (< 100%)
    - 2: Error
"""

import argparse
import sys
from typing import Set, Dict, List, Tuple
from datetime import datetime

import boto3
from botocore.exceptions import ClientError


def get_source_objects(s3, bucket: str, exclude_markers: bool = True) -> Set[str]:
    """Obtiene todos los objetos del bucket origen."""
    keys = set()
    paginator = s3.get_paginator('list_objects_v2')
    
    try:
        for page in paginator.paginate(Bucket=bucket):
            for obj in page.get('Contents', []):
                key = obj['Key']
                
                # Excluir marcadores de carpeta
                if exclude_markers and key.endswith('/'):
                    continue
                
                keys.add(key)
    except ClientError as e:
        print(f"❌ Error listando {bucket}: {e}")
        raise
    
    return keys


def get_backed_up_objects(s3, central_bucket: str, source_bucket: str, 
                          criticality: str) -> Set[str]:
    """Obtiene objetos respaldados desde el bucket central."""
    keys = set()
    
    # Buscar en todas las rutas posibles (incremental + full)
    prefixes = [
        f"backup/criticality={criticality}/backup_type=incremental/",
        f"backup/criticality={criticality}/backup_type=full/",
        f"data/criticality={criticality}/",  # Legacy path
    ]
    
    paginator = s3.get_paginator('list_objects_v2')
    
    for prefix in prefixes:
        try:
            for page in paginator.paginate(Bucket=central_bucket, Prefix=prefix):
                for obj in page.get('Contents', []):
                    key = obj['Key']
                    
                    # Extraer key original desde path de backup
                    # Formato esperado: .../bucket=<source>/year=/month=/day=/hour=/window=.../ORIGINAL_KEY
                    parts = key.split('/')
                    
                    # Buscar índice donde empieza la key original (después de window= o timestamp=)
                    original_start_idx = None
                    for i, part in enumerate(parts):
                        if part.startswith('window=') or part.startswith('timestamp='):
                            original_start_idx = i + 1
                            break
                    
                    if original_start_idx and original_start_idx < len(parts):
                        # Verificar que es del bucket correcto
                        if f"bucket={source_bucket}" in key:
                            original_key = '/'.join(parts[original_start_idx:])
                            if original_key:  # No vacío
                                keys.add(original_key)
        
        except ClientError as e:
            if e.response.get('Error', {}).get('Code') != 'NoSuchKey':
                print(f"⚠️  Error buscando en {prefix}: {e}")
    
    return keys


def validate_bucket(s3, source: str, central: str, criticality: str) -> Tuple[bool, Dict]:
    """Valida un bucket y retorna (success, stats)."""
    
    print(f"\n{'='*80}")
    print(f"🔍 Validando: {source} ({criticality})")
    print(f"{'='*80}")
    
    # Obtener objetos
    print("📊 Listando objetos en origen...")
    source_keys = get_source_objects(s3, source)
    print(f"   ✓ {len(source_keys):,} objetos encontrados")
    
    print("📊 Listando objetos respaldados...")
    backed_up_keys = get_backed_up_objects(s3, central, source, criticality)
    print(f"   ✓ {len(backed_up_keys):,} objetos respaldados")
    
    # Calcular diferencias
    missing_keys = source_keys - backed_up_keys
    extra_keys = backed_up_keys - source_keys
    
    coverage_pct = (len(backed_up_keys) / len(source_keys) * 100) if source_keys else 100
    
    stats = {
        'source_bucket': source,
        'criticality': criticality,
        'total_source': len(source_keys),
        'total_backed_up': len(backed_up_keys),
        'missing_count': len(missing_keys),
        'extra_count': len(extra_keys),
        'coverage_pct': coverage_pct,
        'missing_keys': list(missing_keys)[:50],  # Primeros 50
        'extra_keys': list(extra_keys)[:50],
    }
    
    # Mostrar resultados
    print(f"\n📈 RESULTADOS:")
    print(f"   Objetos en origen:    {stats['total_source']:>10,}")
    print(f"   Objetos respaldados:  {stats['total_backed_up']:>10,}")
    print(f"   Cobertura:            {coverage_pct:>10.2f}%")
    print(f"   Faltantes:            {stats['missing_count']:>10,}")
    if extra_keys:
        print(f"   Extras (huérfanos):   {stats['extra_count']:>10,}")
    
    # Mostrar objetos faltantes
    if missing_keys:
        print(f"\n⚠️  OBJETOS NO RESPALDADOS (primeros 20):")
        for key in list(missing_keys)[:20]:
            print(f"      - {key}")
        if len(missing_keys) > 20:
            print(f"      ... y {len(missing_keys) - 20:,} más")
        
        success = False
    else:
        print("\n✅ Cobertura COMPLETA: Todos los objetos respaldados")
        success = True
    
    return success, stats


def discover_buckets(session: boto3.Session) -> List[Tuple[str, str]]:
    """Descubre buckets etiquetados con BackupEnabled=true."""
    client = session.client('resourcegroupstaggingapi')
    buckets = []
    
    paginator = client.get_paginator('get_resources')
    for page in paginator.paginate(
        TagFilters=[{'Key': 'BackupEnabled', 'Values': ['true']}],
        ResourceTypeFilters=['s3']
    ):
        for resource in page.get('ResourceTagMappingList', []):
            arn = resource['ResourceARN']
            bucket_name = arn.split(':::')[-1]
            
            # Extraer criticidad de tags
            tags = {t['Key']: t['Value'] for t in resource.get('Tags', [])}
            criticality = tags.get('BackupCriticality', 'MenosCritico')
            
            buckets.append((bucket_name, criticality))
    
    return buckets


def main() -> int:
    ap = argparse.ArgumentParser(description='Validar cobertura de backups S3')
    
    ap.add_argument('--source-bucket', help='Bucket origen a validar')
    ap.add_argument('--central-bucket', required=True, help='Bucket central de backups')
    ap.add_argument('--criticality', choices=['Critico', 'MenosCritico', 'NoCritico'],
                    help='Criticidad del bucket origen')
    ap.add_argument('--region', default='eu-west-1', help='AWS region')
    ap.add_argument('--profile', help='AWS profile')
    ap.add_argument('--all-tagged', action='store_true',
                    help='Validar todos los buckets con BackupEnabled=true')
    
    args = ap.parse_args()
    
    # Validar argumentos
    if not args.all_tagged and (not args.source_bucket or not args.criticality):
        ap.error('Se requiere --source-bucket y --criticality, o usar --all-tagged')
    
    # Crear sesión
    session = boto3.Session(profile_name=args.profile, region_name=args.region)
    s3 = session.client('s3')
    
    # Determinar buckets a validar
    buckets_to_validate: List[Tuple[str, str]] = []
    
    if args.all_tagged:
        print("🔎 Descubriendo buckets etiquetados...")
        buckets_to_validate = discover_buckets(session)
        print(f"   ✓ {len(buckets_to_validate)} buckets encontrados")
    else:
        buckets_to_validate = [(args.source_bucket, args.criticality)]
    
    if not buckets_to_validate:
        print("⚠️  No se encontraron buckets para validar")
        return 0
    
    # Validar cada bucket
    all_success = True
    all_stats = []
    
    for source, crit in buckets_to_validate:
        try:
            success, stats = validate_bucket(s3, source, args.central_bucket, crit)
            all_stats.append(stats)
            
            if not success:
                all_success = False
        
        except Exception as e:
            print(f"❌ Error validando {source}: {e}")
            all_success = False
    
    # Resumen global
    if len(all_stats) > 1:
        print(f"\n{'='*80}")
        print("📊 RESUMEN GLOBAL")
        print(f"{'='*80}")
        
        total_source = sum(s['total_source'] for s in all_stats)
        total_backed = sum(s['total_backed_up'] for s in all_stats)
        total_missing = sum(s['missing_count'] for s in all_stats)
        
        global_coverage = (total_backed / total_source * 100) if total_source else 100
        
        print(f"   Buckets validados:    {len(all_stats)}")
        print(f"   Objetos totales:      {total_source:,}")
        print(f"   Objetos respaldados:  {total_backed:,}")
        print(f"   Cobertura global:     {global_coverage:.2f}%")
        print(f"   Total faltantes:      {total_missing:,}")
        
        if total_missing > 0:
            print(f"\n⚠️  Buckets con cobertura incompleta:")
            for s in all_stats:
                if s['missing_count'] > 0:
                    print(f"      • {s['source_bucket']}: {s['coverage_pct']:.2f}% "
                          f"({s['missing_count']:,} faltantes)")
    
    return 0 if all_success else 1


if __name__ == '__main__':
    sys.exit(main())