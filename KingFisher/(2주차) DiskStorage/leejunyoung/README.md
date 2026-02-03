# DiskStorage 분석

Kingfisher의 DiskStorage 컴포넌트에 대한 분석 문서입니다.

## 문서 목록

- [**initializer.md**](files/initializer.md) - 초기화 메서드 (convenience init, init) 분석
- [**properties.md**](files/properties.md) - DiskStorage의 주요 프로퍼티 분석
- [**config.md**](files/config.md) - Config 구조체 및 설정 값 분석
- [**creation.md**](files/creation.md) - Creation 구조체 및 디렉토리 경로 생성 로직 분석
- [**filemeta.md**](files/filemeta.md) - FileMeta 구조체 및 파일 메타데이터 관리 분석
- [**setupmethod.md**](files/setupmethod.md) - setupCacheChecking, prepareDirectory 메서드 분석
- [**cachemethod.md**](files/cachemethod.md) - 캐시 CRUD 메서드 (store, value, isCached, remove) 분석
- [**cachemenagementmethod.md**](files/cachemenagementmethod.md) - 캐시 관리 메서드 (removeExpiredValues, removeSizeExceededValues 등) 분석
