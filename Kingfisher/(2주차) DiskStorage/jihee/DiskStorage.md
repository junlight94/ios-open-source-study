- Memory Disk와 동일하게 네임스페이스 enum 구조에 Config, Backend로 구성되어 있음
- 영속적이고 대용량이지만 느린 저장소
- 메모리 캐시가 모두 사라졌을 때, 앱을 재시작하면 모든 이미지를 인터넷에서 다시 재다운로드하기 때문에 데이터 낭비 및 느린 로딩

## Backend

> 실제 디스크 저장소
> 
- **config**: 스토리지 설정 (thread-safe하게 접근)
- **directoryURL**: 실제 저장 경로
- **maybeCached**: 캐시된 파일 이름 집합 (성능 최적화용)
- **storageReady**: 스토리지 초기화 성공 여부

### 핵심 메서드

- 저장
    
    ```swift
    store(value:forKey:expiration:writeOptions:forcedExtension:)
    ```
    
    - 값을 Data로 변환하여 파일로 저장
    - 파일 속성에 생성일자와 만료일자 설정
    - 폴더가 삭제된 경우 재생성 후 재시도
- 조회
    
    ```swift
    value(forKey:forcedExtension:extendingExpiration:)
    ```
    
    - 파일 존재 여부 및 만효 여부 확인
    - Data를 원래 타입으로 변환
    - 접근 시 만료 시간 연장 가능
- **캐시 확인 (isCached)**
    
    ```swift
    isCached(forKey:forcedExtension:)
    ```
    
    - 실제 데이터 로드 없이 캐시 유효성만 확인
    - 성능상 유리
- **삭제**
    - `remove(forKey:)`: 특정 키의 파일 삭제
    - `removeAll()`: 전체 삭제
    - `removeExpiredValues()`: 만료된 파일들 삭제
    - `removeSizeExceededValues()`: 용량 초과시 LRU 방식으로 삭제
- **유틸리티**
    - `cacheFileURL(forKey:)`: 캐시 파일 URL 생성
    - `totalSize()`: 전체 캐시 크기 계산

## Config

> 저장소의 설정 관리
> 
- **sizeLimit**: 최대 용량 (바이트, 0은 무제한)
- **expiration**: 만료 정책 (기본 7일)
- **pathExtension**: 파일 확장자
- **usesHashedFileName**: 파일명 해싱 여부 (기본 true)
- **autoExtAfterHashedFileName**: 해싱 후 원본 확장자 추가 여부
- **cachePathBlock**: 캐시 경로 커스터마이징 클로저
- **name**: 캐시 식별 이름

## FileMeta

> 파일 메타 데이터
> 
- 파일 URL, 접근 일자, 만료 예정일, 디렉토리 여부, 파일 크기 등
- 만료 여부 판단 및 만료 시간 연장 기능

## Creation

> 초기화 헬퍼
> 

---

### 에러 처리

- 폴더 삭제 시 자동 재생성
- 저장 실패 시 명확한 에러 메시지
- Storage not ready 상태 관리

### 만료 관리

- 파일 속성에 만료 정보 저장
- 접근 시 자동 만료 체크
- 읽기 시 만료 시간 연장 옵션 (none/cacheTime/expirationTime)

### 용량 관리

- LRU(Least Recently Used) 방식
- 생성일자 기준 정렬하여 오래된 파일부터 삭제
- sizeLimit의 1/2까지 삭제

# 성능 최적화 - maybeCached

### 문제 상황

- 디스크 I/O는 느림
- 일반적인 캐시 확인은 fileExists(at:) 으로 파일이 존재하는지 확인

### 해결 방법

- 디스크 접근 전, false positive 체크: maybeCached에는 있지만 실제 디스크에는 없는 경우를 체크함

```swift
func value(
            forKey key: String,
            referenceDate: Date,
            actuallyLoad: Bool,
            extendingExpiration: ExpirationExtending,
            forcedExtension: String?
        ) throws -> T?
        {
            guard storageReady else {
                throw KingfisherError.cacheError(reason: .diskStorageIsNotReady(cacheURL: directoryURL))
            }

            let fileManager = config.fileManager
            let fileURL = cacheFileURL(forKey: key, forcedExtension: forcedExtension)
            let filePath = fileURL.path

						// 1단계: 빠른 메모리 체크 (false-positive 가능)
            let fileMaybeCached = maybeCachedCheckingQueue.sync {
                return maybeCached?.contains(fileURL.lastPathComponent) ?? true
            }
            guard fileMaybeCached else {
                return nil  // fileMaybeCache가 false 이면 확실히 없음 → 디스크 접근 생략
            }
            
            // 실제 디스크 체크
            guard fileManager.fileExists(atPath: filePath) else {
                return nil
            }

            let meta: FileMeta
            do {
                let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey]
                meta = try FileMeta(fileURL: fileURL, resourceKeys: resourceKeys)
            } catch {
                throw KingfisherError.cacheError(
                    reason: .invalidURLResource(error: error, key: key, url: fileURL))
            }

            if meta.expired(referenceDate: referenceDate) {
                return nil
            }
            if !actuallyLoad { return T.empty }

            do {
                let data = try Data(contentsOf: fileURL)
                let obj = try T.fromData(data)
                metaChangingQueue.async {
                    meta.extendExpiration(with: self.config.fileManager, extendingExpiration: extendingExpiration)
                }
                return obj
            } catch {
                throw KingfisherError.cacheError(reason: .cannotLoadDataFromDisk(url: fileURL, error: error))
            }
        }
```

- 디스크 접근 전 빠른 false positive 체크
- **비동기 초기화**: 백그라운드에서 파일 목록 로드
- **actuallyLoad 옵션**: 존재 여부만 확인 시 데이터 로드 생략

## 파일 시스템 속성 활용

- FileManager Attributes 만료 시간으로 사용
    
    ```swift
    let attributes: [FileAttributeKey : Any] = [
        .creationDate: now.fileAttributeDate,              // 마지막 접근 시간
        .modificationDate: expiration.estimatedExpirationSinceNow.fileAttributeDate  // 만료 예정 시간
    ]
    try config.fileManager.setAttributes(attributes, ofItemAtPath: fileURL.path)
    ```
    
    - 별도의 메타데이터 파일을 생성할 경우에는 파일 개수가 2배, I/O도 2배
    - 파일 시스템 속성 활용 시 속성을 메타데이터로 사용하기 때문에 추가 파일 없이 파일시스템이 관리할 수 있음
- FileMeta 구조체
    
    ```swift
    struct FileMeta {
        let url: URL
        let lastAccessDate: Date?           // creationDate에서 읽음
        let estimatedExpirationDate: Date?  // modificationDate에서 읽음
        let isDirectory: Bool
        let fileSize: Int
        
        init(fileURL: URL, resourceKeys: Set<URLResourceKey>) throws {
            let meta = try fileURL.resourceValues(forKeys: resourceKeys)
            self.init(
                fileURL: fileURL,
                lastAccessDate: meta.creationDate,  // 마지막 접근 시간
                estimatedExpirationDate: meta.contentModificationDate,  // modificationDate
                isDirectory: meta.isDirectory ?? false,
                fileSize: meta.fileSize ?? 0
            )
        }
        
        func expired(referenceDate: Date) -> Bool {
            return estimatedExpirationDate?.isPast(referenceDate: referenceDate) ?? true
        }
    }
    ```
    
    - creationDate: 파일 생성 시각이 아닌 **마지막 접근 시간,** 파일을 읽을 때마다 업데이트
    - modificationDate: 파일 내용 수정 시각이 아닌 **만료 예정 시간**

## Thread Safety

`propertyQueue`: config 접근 동기화

```swift
private let propertyQueue = DispatchQueue(label: "...") // 한 번에 하나만 실행
private var _config: Config // 실제 데이터는 보호

public var config: Config { // 모든 접근을 Queue를 통하도록 강제
    get { propertyQueue.sync { _config } } // sync : 완료될 때까지 대기
    set { propertyQueue.sync { _config = newValue } }
}
```

- Config는 struct 타입으로 복사될 때 모든 프로퍼티가 복사됨
- thread safe한 구조를 갖고 있지 않다면 다른 스레드에서 복사해서 읽을 때 race condition
- Serial Queue + sync를 이용해서 해결
    
    ```swift
    // Thread 1: 쓰기
    backend.config = newConfig
    
    // 내부 동작
    propertyQueue.sync {
        _config = newConfig  // ← 이 블록 실행 중에는 다른 스레드 차단됨
    }
    
    // Thread 2: 읽기 (동시 시도)
    let config = backend.config
    
    // 내부 동작
    propertyQueue.sync {     // ← Thread 1이 끝날 때까지 대기
        return _config       //   대기 후 실행
    }
    ```
    
    - Serial Queue가 보장한는 것
        - Matual Exclusion(상호 배제): 한번에 하나의 작업만 실행 가능
        - Atomicity(원자성) : 블록 하나가 원자적으로 실행, 중간에 다른 스레드 끼어들 수 없음
        - 순서 보장: 가능한 실행 순서들은 있지만 각 스레드에서 순서가 보장되어 중간에 끊기지 않고 완전한 실행 가능
- `maybeCachedCheckingQueue`: 캐시 집합 접근 동기화
    
    ```swift
    // Cache 확인을 위한 Set 초기화
    private func setupCacheChecking() {
        DispatchQueue.global(qos: .default).async {
            do {
                let allFiles = try self.config.fileManager.contentsOfDirectory(atPath: self.directoryURL.path)
                let maybeCached = Set(allFiles)
                self.maybeCachedCheckingQueue.async {
                    self.maybeCached = maybeCached
                }
            } catch {
                self.maybeCachedCheckingQueue.async {
                    // Just disable the functionality if we fail to initialize it properly. This will just revert to
                    // the behavior which is to check file existence on disk directly.
                    self.maybeCached = nil
                }
            }
        }
    }
    
    // in store Method
    public func store(
        value: T,
        forKey key: String,
        expiration: StorageExpiration? = nil,
        writeOptions: Data.WritingOptions = [],
        forcedExtension: String? = nil
    ) throws
    {
    //...
        maybeCachedCheckingQueue.async {
            self.maybeCached?.insert(fileURL.lastPathComponent) // 캐시 데이터 저장
        }
    // ...
    }
    
    func value(
        forKey key: String,
        referenceDate: Date,
        actuallyLoad: Bool,
        extendingExpiration: ExpirationExtending,
        forcedExtension: String?
    ) throws -> T?
    {
    		// ....
        let fileMaybeCached = maybeCachedCheckingQueue.sync {
            return maybeCached?.contains(fileURL.lastPathComponent) ?? true // 캐시 여부 확인
        }
        // ....
     }
    
    ```
    
    - 읽기 : sync 결과가 즉시 필요함 → 즉, ***정확한 정보가 지금 당장 필요***
        - fileMaybeCached 라는 변수가 즉시 필요 → 반환값이 있어야 함
        - fileMaybeCached에 따라 다음 동작 달라짐 (Disk I/O 생략)
    - 쓰기 : 결과를 기다릴 필요가 없음 → 즉, ***언젠가 업데이트만 되면 됨***
        - mayCached는 또한 업데이트가 필수가 아니기 때문에 업데이트가 되지 않아도 기능 정상 작동
        - 나중에 업데이트 되어도 되기 때문에 기다리지 않고 함수 종료 → 성능 향상
- `metaChangingQueue`: 파일 메타데이터 변경 동기
    - CahceName 을 label로 쓰기 위해서 init 내부에서 초기화 (런타임 결정)
    - 파일 메타데이터 업데이트를 비동기로 처리, 메타 데이터 업데이트를 기다리지 않고 object를 즉시 반환함
        - 내부 정책 관리에 사용되는 메타 데이터 업데이트를 기다릴 필요없음
            - 파일의 `creationDate` (마지막 접근 시간) 갱신
            - 파일의 `modificationDate` (만료 예정 시간) 갱신
        
        ₩
        

## LRU 캐시 정책

크기 제한 초과 시 **오래된 파일 삭제**

1. 현재 size가 sizeLimit보다 적다면 모든 파일의 메타데이터를 수집(FileMeta 구조체 배열)
2. 마지막 접근 시간 순으로 정렬 (최근 접근한 것이 앞)
3. 뒤에서부터(오래된 것부터) 삭제 : sizeLimit의 절반까지 삭제
    
    절반인 이유 : 너무 적게 삭제하게 되면(sizeLimit까지만 삭제) 계속 삭제 작업이 발생. 정리 빈도를 줄이고 성능 향상
    

## 자동 에러 복구

사용자는 에러를 보지 못하게 자동 복구 시도 

- 자동 복구 매커니즘 (`isFolderMissing`)
    - 폴더가 없는 에러가 발생하면 폴더 재생성 후 재시도
    
    ```swift
    fileprivate extension Error {
        var isFolderMissing: Bool {
            // NSCocoaErrorDomain, code 4: "No such file or directory"
            let nsError = self as NSError
            guard nsError.domain == NSCocoaErrorDomain, 
                  nsError.code == 4 else {
                return false
            }
            
            // Underlying error: POSIX error 2 (ENOENT)
            guard let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError else {
                return false
            }
            guard underlyingError.domain == NSPOSIXErrorDomain, 
                  underlyingError.code == 2 else {
                return false
            }
            
            return true
        }
    }
    ```