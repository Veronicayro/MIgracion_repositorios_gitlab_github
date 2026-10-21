#!/usr/bin/env bash
#


main() {
  echo "MENSAJE INICIAL"
  
  
  #MIGRATION_SCRIPT="${pwd}/migrar_repositorios.sh"
  #CERTIFICATION_SCRIPT="${pwd}/validar_integridad_migracion.sh"
  
  #if ! bash "${MIGRATION_SCRIPT}"; then
  #  echo "ERROR: La migración terminó con errores. No se ejecutará la certificación." >&2
  #  return 1
  #fi
  
  #if ! bash "${CERTIFICATION_SCRIPT}"; then
  #  echo "ERROR: La certificación terminó con errores." >&2
  #  return 1
  #fi
  
  return 0
}

main "$@"
