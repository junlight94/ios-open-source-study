# ImageCache.swift 학습 정리

## 1. 개요

`ImageCache`는 Kingfisher 라이브러리의 핵심 컴포넌트 중 하나로, **메모리 캐시(MemoryStorage)**와 **디스크 캐시(DiskStorage)**를 결합한 **하이브리드 2단계 캐싱 시스템**이다.

이미지 로딩 파이프라인에서 `KingfisherManager`가 이미지를 요청하면, `ImageCache`가 메모리 → 디스크 순서로 캐시를 탐색하고, 캐시 미스 시 다운로드된 이미지를 양쪽 캐시에 저장하는 역할을 수행한다.

---

## 2. 클래스 구조와 설계 원칙

### 핵심 프로퍼티

```swift
public let memoryStorage: MemoryStorage.Backend<KFCrossPlatformImage>
public let diskStorage: DiskStorage.Backend<Data>
private let ioQueue: DispatchQueue
```

- **memoryStorage**: `NSCache` 기반의 메모리 캐시. 제네릭 타입이 `KFCrossPlatformImage`(= UIImage/NSImage)로, 디코딩된 이미지 객체를 직접 저장한다.
- **diskStorage**: 파일 시스템 기반의 디스크 캐시. 제네릭 타입이 `Data`로, 직렬화된 바이너리 데이터를 저장한다.
- **ioQueue**: 디스크 I/O 전용 직렬 큐. 모든 디스크 관련 작업이 이 큐를 통해 순차적으로 실행된다.

**왜 memoryStorage는 `KFCrossPlatformImage`이고 diskStorage는 `Data`인가?**

- 메모리 캐시는 이미지를 **즉시 화면에 표시**하기 위한 것이므로, 이미 디코딩된 이미지 객체를 저장한다.
- 디스크 캐시는 **영속적인 저장**이 목적이므로, 직렬화된 바이너리 데이터(PNG, JPEG 등)를 파일로 저장한다. 디스크에서 읽을 때는 `CacheSerializer`가 Data → Image 변환을 수행한다.

---

## 3. 이니셜라이저 체인

ImageCache는 여러 이니셜라이저를 제공하며, 최종적으로 모두 지정(Designated) 이니셜라이저로 수렴한다:

```
init(name: String)                              // 편의 이니셜라이저 (가장 단순)
    └→ init(noThrowName:cacheDirectoryURL:diskCachePathClosure:)  // 내부 편의 이니셜라이저
        └→ init(memoryStorage:diskStorage:)      // 지정 이니셜라이저

init(name:cacheDirectoryURL:diskCachePathClosure:) throws  // 편의 이니셜라이저 (커스텀 경로)
    └→ init(memoryStorage:diskStorage:)          // 지정 이니셜라이저
```

### 3.1 `init(name:)` vs `init(name:cacheDirectoryURL:diskCachePathClosure:) throws`

둘의 핵심 차이는 에러 처리 방식이다:

- `init(name:)`: 내부에서 `noThrowConfig`를 사용하여 디스크 디렉토리 생성 실패를 무시한다. `ImageCache.default` 같은 싱글턴 생성에 적합하다. 런타임에 디렉토리 생성이 실패해도 앱이 크래시하지 않고, 나중에 실제 파일 쓰기 시 다시 시도한다.
- `init(name:cacheDirectoryURL:diskCachePathClosure:) throws`: 디스크 디렉토리 생성 실패 시 에러를 던진다. 커스텀 경로를 지정할 때 사용하며, 초기화 실패를 명시적으로 처리할 수 있다.

### 3.2 메모리 스토리지 생성 로직

```swift
private static func createMemoryStorage() -> MemoryStorage.Backend<KFCrossPlatformImage> {
    let totalMemory = ProcessInfo.processInfo.physicalMemory
    let costLimit = totalMemory / 4
    let memoryStorage = MemoryStorage.Backend<KFCrossPlatformImage>(config:
        .init(totalCostLimit: (costLimit > Int.max) ? Int.max : Int(costLimit)))
    return memoryStorage
}
```

디바이스 물리 메모리의 **1/4**을 메모리 캐시의 최대 비용 제한으로 설정한다. 

예를 들어:

- iPhone (6GB RAM): 1.5GB 제한
- iPhone (4GB RAM): 1GB 제한

이 값은 NSCache의 `totalCostLimit`으로 설정되며, 이미지가 추가될 때 `cacheCost` (비트맵 크기)가 이 제한을 초과하면 NSCache가 자동으로 가장 오래된 항목부터 퇴출(evict)한다.

`costLimit > Int.max` 검사는 32비트 시스템 호환성을 위한 것이다. `physicalMemory`는 `UInt64`이므로 이론적으로 `Int.max`를 초과할 수 있다.

### 3.3 시스템 알림 등록

이니셜라이저에서 `Task { @MainActor in ... }`을 사용하여 시스템 알림을 등록한다:

| 플랫폼 | 알림 | 동작 |
|--------|------|------|
| iOS/tvOS | `didReceiveMemoryWarningNotification` | 메모리 캐시 전체 삭제 |
| iOS/tvOS | `willTerminateNotification` | 만료된 디스크 캐시 정리 |
| iOS/tvOS | `didEnterBackgroundNotification` | 백그라운드 태스크로 만료 디스크 캐시 정리 |
| macOS | `willResignActiveNotification` | 만료된 디스크 캐시 정리 |
| watchOS | - | 없음 |

이렇게 앱 생명주기 이벤트에 반응하여 자동으로 캐시를 관리한다. 개발자가 별도로 정리 코드를 작성하지 않아도 된다.

---

## 4. 이미지 저장 (Store)

### 4.1 핵심 저장 흐름

```
store() 호출
    │
    ├── 1. computedKey 계산 (key + processorIdentifier)
    │
    ├── 2. memoryStorage.storeNoThrow() [동기, 즉시]
    │
    ├── toDisk == false? → 완료, 콜백 호출
    │
    └── 3. ioQueue.async { ... }
            ├── CacheSerializer.data(with:original:) [이미지 → Data 직렬화]
            ├── syncStoreToDisk() → diskStorage.store() [파일 시스템에 기록]
            └── 콜백 호출
```

### 4.2 computedKey (계산된 캐시 키)

```swift
let computedKey = key.computedKey(with: identifier)
```

같은 원본 이미지라도 다른 프로세서로 처리하면 다른 결과물이 나오므로, 캐시 키에 프로세서 식별자를 포함시켜야 한다.

**예시:**

- 원본: `"https://example.com/image.png"` → 키: `"https://example.com/image.png"`
- 리사이징: `"https://example.com/image.png"` + `"ResizingProcessor(100x100)"` → 키: `"https://example.com/image.png@ResizingProcessor(100x100)"`

이로써 같은 URL의 이미지라도 리사이징, 블러 등 다른 처리를 거친 결과물을 각각 독립적으로 캐싱할 수 있다.

### 4.3 메모리 저장과 디스크 저장의 비대칭성

**메모리 저장 (동기, 즉시):**
```swift
memoryStorage.storeNoThrow(value: image, forKey: computedKey, expiration: options.memoryCacheExpiration)
```

- NSCache에 직접 저장한다.
- NSLock으로 보호되며, 매우 빠르다.
- 실패하지 않는다 (타입이 `Result<(), Never>`).

**디스크 저장 (비동기, ioQueue에서):**
```swift
ioQueue.async {
    let data = serializer.data(with: image, original: original)
    self.syncStoreToDisk(data, ...)
}
```

- 이미지를 먼저 Data로 직렬화해야 한다 (CPU 작업).
- 파일 시스템에 기록한다 (I/O 작업).
- 직렬화 또는 파일 쓰기가 실패할 수 있다.

이 비대칭적 설계 덕분에, 메모리 캐시에는 즉시 저장되어 다음 조회 시 바로 사용할 수 있고, 느린 디스크 저장은 백그라운드에서 수행된다.

### 4.4 TempProcessor 패턴

```swift
struct TempProcessor: ImageProcessor {
    let identifier: String
    func process(item: ImageProcessItem, options: KingfisherParsedOptionsInfo) -> KFCrossPlatformImage? {
        return nil
    }
}
```

외부 공개 API인 `store(_:original:forKey:processorIdentifier:...)` 메서드 내부에서 사용되는 임시 구조체이다. 실제 이미지 처리 기능은 없고(`process()`가 `nil` 반환), 오직 `identifier` 프로퍼티만 사용된다. 이를 통해 `KingfisherParsedOptionsInfo`를 구성하여 내부 핵심 `store()` 메서드를 호출한다.

이는 공개 API에서는 간단한 파라미터를 받되, 내부적으로는 통일된 옵션 기반 인터페이스를 사용하기 위한 어댑터 패턴이다.

---

## 5. 이미지 조회 (Retrieve)

### 5.1 조회 흐름 (가장 중요한 부분)

```
retrieveImage(forKey:options:callbackQueue:completionHandler:)
    │
    ├── 1. 메모리 캐시 확인 (동기적)
    │   └── 히트 → .success(.memory(image)) 반환
    │
    ├── 2. fromMemoryCacheOrRefresh 옵션 확인
    │   └── true → .success(.none) 반환 (디스크 탐색 건너뜀)
    │
    └── 3. 디스크 캐시 확인 (비동기적)
        ├── 이미지 있음 → 메모리 캐시에 워밍 → .success(.disk(image)) 반환
        ├── 이미지 없음 → .success(.none) 반환
        └── 에러 → .failure(error) 반환
```

### 5.2 캐시 워밍 (Cache Warming)

디스크에서 이미지를 찾으면, 자동으로 메모리 캐시에도 저장한다:

```swift
self.store(image, forKey: key, options: cacheOptions, toDisk: false) { _ in
    callbackQueue.execute { completionHandler(.success(.disk(image))) }
}
```

`toDisk: false`로 설정하여 디스크에는 다시 쓰지 않는다 (이미 디스크에 있으므로). 이 과정을 통해, 한 번 디스크에서 읽은 이미지는 이후에는 메모리 캐시에서 즉시 반환된다.

### 5.3 `fromMemoryCacheOrRefresh` 옵션

이 옵션이 `true`이면, 메모리 캐시에 없는 경우 디스크 캐시를 확인하지 않고 바로 `.none`을 반환한다. 이는 다음과 같은 시나리오에서 유용하다:

- 테이블뷰/컬렉션뷰에서 빠른 스크롤 시, 메모리에 없는 이미지는 디스크에서 읽는 대신 네트워크에서 새로 다운로드하는 것이 더 나을 수 있다.
- 디스크 I/O가 병목이 되는 상황에서 성능 최적화를 위해 사용한다.

### 5.4 디스크 캐시 조회의 동기/비동기 선택

```swift
let loadingQueue: CallbackQueue = options.loadDiskFileSynchronously ? .untouch : .dispatch(ioQueue)
```

- `loadDiskFileSynchronously = false` (기본): ioQueue에서 비동기적으로 로딩. 호출자가 블로킹되지 않는다.
- `loadDiskFileSynchronously = true`: 호출자의 현재 큐에서 동기적으로 로딩. 이미 백그라운드 큐에서 호출하는 경우에 유용하다.

### 5.5 backgroundDecode 옵션

```swift
if options.backgroundDecode {
    image = image?.kf.decoded(scale: options.scaleFactor)
}
```

`UIImage`는 기본적으로 **지연 디코딩(lazy decoding)**을 수행한다. 즉, 실제로 화면에 그려질 때까지 비트맵 디코딩을 미룬다. 이 디코딩이 메인 스레드에서 발생하면 스크롤 성능에 영향을 줄 수 있다.

`backgroundDecode`를 활성화하면 디스크에서 읽은 직후 (ioQueue 또는 백그라운드 큐에서) 미리 디코딩을 수행하여, 메인 스레드에서의 디코딩 지연을 방지한다.

---

## 6. 캐시 정리 (Cleaning)

### 6.1 수동 정리 vs 자동 정리

| 메서드 | 유형 | Notification 발송 |
|--------|------|------------------|
| `clearMemoryCache()` | 수동 | 없음 |
| `clearDiskCache()` | 수동 | **없음** |
| `cleanExpiredDiskCache()` | 자동 | **있음** (`KingfisherDidCleanDiskCache`) |

`clearDiskCache()`는 모든 캐시를 강제로 삭제하는 사용자 주도 동작이므로 Notification을 발송하지 않는다. 반면 `cleanExpiredDiskCache()`는 만료/사이즈 초과 기반의 자동 정리이므로, 어떤 파일이 삭제되었는지 알림을 발송한다.

### 6.2 만료 디스크 캐시 정리 흐름

```swift
ioQueue.async {
    var removed: [URL] = []
    let removedExpired = try self.diskStorage.removeExpiredValues()        // 1. 만료 파일 삭제
    removed.append(contentsOf: removedExpired)
    let removedSizeExceeded = try self.diskStorage.removeSizeExceededValues()  // 2. 사이즈 초과 삭제
    removed.append(contentsOf: removedSizeExceeded)
    if !removed.isEmpty {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .KingfisherDidCleanDiskCache, ...)  // 3. 알림
        }
    }
}
```

정리 순서:

1. **만료된 파일 삭제**: `modificationDate`(= 예상 만료일)가 현재 시간을 지난 파일을 삭제한다.
2. **사이즈 초과 파일 삭제**: 전체 캐시 크기가 `config.sizeLimit`을 초과하면, LRU(Least Recently Used) 방식으로 가장 오래 접근하지 않은 파일부터 삭제하여 **제한의 절반**까지 줄인다.
3. **알림 발송**: 삭제된 파일이 있으면 메인 큐에서 Notification을 발송한다.

### 6.3 백그라운드 디스크 캐시 정리

iOS에서는 앱이 백그라운드로 진입하면 제한된 실행 시간만 허용된다. `backgroundCleanExpiredDiskCache()`는 `UIApplication.beginBackgroundTask`를 사용하여 시스템에 "아직 작업 중"임을 알리고, 만료 캐시 정리가 완료될 때까지 실행 시간을 확보한다.

```swift
let createdTask = sharedApplication.beginBackgroundTask(
    withName: "Kingfisher:backgroundCleanExpiredDiskCache",
    expirationHandler: endBackgroundTaskIfNeeded
)
```

내부에서 `BackgroundTaskState` actor를 사용하여 백그라운드 태스크 식별자의 동시 접근을 안전하게 관리한다. actor는 Swift Concurrency에서 데이터 경쟁을 방지하는 참조 타입이다.

---

## 7. 캐시 상태 확인

### 7.1 `imageCachedType(forKey:processorIdentifier:forcedExtension:)`

메모리 → 디스크 순서로 캐시 존재 여부를 확인하고 `CacheType`을 반환한다. 동기적으로 동작하며, 디스크 확인 시 파일 메타데이터만 확인하므로 비교적 빠르다.

### 7.2 캐시 파일 경로 관련

- `cachePath(forKey:)`: 캐시 파일의 **예상 경로**를 반환한다. 파일이 실제로 존재하는지는 보장하지 않는다.
- `cacheFileURLIfOnDisk(forKey:)`: 파일이 **실제로 존재하는 경우에만** URL을 반환한다.
- `hash(forKey:)`: 캐시 파일명(SHA256 해시)을 반환한다.

---

## 8. Swift Concurrency 지원 (async/await)

파일 하단부에는 기존 콜백 기반 메서드들의 async/await 래퍼가 정의되어 있다:

```swift
open func store(...) async throws {
    try await withCheckedThrowingContinuation { continuation in
        store(...) {
            continuation.resume(with: $0.diskCacheResult)
        }
    }
}
```

`withCheckedThrowingContinuation`을 사용하여 콜백 패턴을 async/await으로 브릿징한다. "Checked"는 런타임에 continuation이 정확히 한 번만 resume되는지 검증하며, 두 번 resume하거나 resume하지 않으면 크래시한다 (디버그 빌드에서).

---

## 9. 보조 타입들

### 9.1 `CacheType` 열거형

```swift
public enum CacheType: Sendable {
    case none    // 캐시되지 않음
    case memory  // 메모리 캐시
    case disk    // 디스크 캐시
}
```

`Sendable`을 준수하여 Swift Concurrency 컨텍스트에서 안전하게 전달할 수 있다.

### 9.2 `CacheStoreResult` 구조체

메모리와 디스크 저장 결과를 별도로 추적한다. 메모리 저장은 절대 실패하지 않으므로 `Result<(), Never>`이고, 디스크 저장은 실패 가능하므로 `Result<(), KingfisherError>`이다.

### 9.3 `ImageCacheResult` 열거형

캐시 조회 결과를 나타내며, 이미지를 연관 값으로 포함한다. `CacheType`과 유사하지만, 이미지 데이터를 직접 운반하는 역할이 추가된 것이 차이점이다.

### 9.4 `Data: DataTransformable` 확장

`Data` 타입이 `DataTransformable` 프로토콜을 준수하도록 확장한다. `DiskStorage.Backend<Data>`에서 사용하기 위함이며, `toData()`와 `fromData()`가 항등 변환(identity transform)인 것이 특징이다.

### 9.5 `KFCrossPlatformImage: CacheCostCalculable` 확장

이미지의 비트맵 크기를 `cacheCost`로 반환하여, NSCache가 메모리 제한 기반 자동 퇴출을 수행할 때 사용한다.

### 9.6 `KingfisherWrapper<UIApplication>.shared`

앱 확장(App Extension)에서 `UIApplication.shared`에 직접 접근할 수 없는 문제를 우회하기 위한 런타임 동적 디스패치 구현이다. `NSSelectorFromString("sharedApplication")`과 `perform(_:)`을 사용하여, 앱 확장 환경에서는 `nil`을 반환하고 정상 앱에서는 `UIApplication` 인스턴스를 반환한다.

### 9.7 `String.computedKey(with:)`

프로세서 식별자를 키에 결합하여 최종 캐시 키를 생성하는 유틸리티 메서드이다. 같은 URL의 이미지라도 다른 프로세서로 처리하면 다른 캐시 키를 가지도록 한다.

---

## 10. 전체 아키텍처에서의 위치

```
UIImageView.kf.setImage(with: url)
    │
    └→ KingfisherManager.retrieveImage()
        │
        ├→ ImageCache.retrieveImage()        ◀── 여기
        │   ├→ MemoryStorage (NSCache + NSLock)
        │   └→ DiskStorage (FileManager + ioQueue)
        │
        └→ ImageDownloader.downloadImage()
            └→ 다운로드 완료 후 → ImageCache.store() ◀── 여기
```

---

## 11. ioQueue의 역할과 MemoryStorage의 NSLock 차이

### 질문의 배경

`MemoryStorage.swift`의 `storeNoThrow`에서는 `NSLock`으로 동기화하고 있는데, 왜 `DiskStorage.swift`의 `store` 메서드에는 자체적인 Lock이 없고, 대신 `ImageCache.swift`에서 `ioQueue`로 관리하는 것인가?

### 왜 MemoryStorage는 NSLock을 사용하는가?

MemoryStorage의 핵심 저장소는 `NSCache`와 `Set<String>`(keys)이다. 이 두 데이터 구조에 대한 접근을 보호해야 한다.

`NSCache` 자체는 thread-safe하지만, `keys` Set은 thread-safe하지 않다. 따라서 `keys`에 대한 읽기/쓰기를 보호하기 위해 `NSLock`이 필요하다.

**MemoryStorage에서 NSLock이 적합한 이유:**
1. **연산이 매우 빠르다**: NSCache의 `setObject`와 Set의 `insert`는 O(1)에 가까운 인메모리 연산이다.
2. **동기적 결과가 필요하다**: `retrieveImageInMemoryCache()`는 동기적으로 즉시 결과를 반환해야 한다. 비동기 큐를 사용하면 호출자가 콜백을 기다려야 한다.
3. **Lock 보유 시간이 극히 짧다**: 마이크로초 단위의 연산이므로, Lock으로 인한 스레드 블로킹이 사실상 무시할 만한 수준이다.

### 왜 DiskStorage에는 자체 Lock이 없고 ImageCache의 ioQueue를 사용하는가?

**1. 디스크 I/O는 느린 작업이다**

디스크 파일 읽기/쓰기는 밀리초~수십 밀리초 단위의 시간이 소요된다. 만약 NSLock으로 보호하면:
- Lock을 잡고 있는 동안 다른 모든 스레드가 **블로킹**(대기)된다.
- 특히 메인 스레드가 블로킹되면 UI가 멈춘다 (프레임 드롭).

```
// ❌ 만약 DiskStorage 내부에서 NSLock을 사용한다면:
func store(value: T, forKey key: String) {
    lock.lock()         // 다른 스레드는 여기서 블로킹됨
    defer { lock.unlock() }
    let data = value.toData()    // CPU 작업
    data.write(to: fileURL)      // 디스크 I/O (느림!)
    setAttributes(...)           // 디스크 I/O (느림!)
}
```

이 경우, `store()`를 호출하는 스레드는 파일 쓰기가 완료될 때까지 Lock을 잡고 있으며, 그 동안 다른 스레드에서 `store()`나 `value(forKey:)`를 호출하면 전부 대기해야 한다.

**2. ioQueue(직렬 큐)는 논블로킹이다**

직렬 DispatchQueue를 사용하면:
- `ioQueue.async { ... }`로 호출하면 **호출자는 즉시 반환**된다.
- 작업은 큐에 enqueue되어 **순차적으로** 실행된다.
- 호출자(메인 스레드 포함)가 블로킹되지 않는다.

```
// ✅ 현재 구현 (ImageCache에서 ioQueue 사용):
ioQueue.async {
    // 이 블록은 ioQueue에서 순차적으로 실행됨
    let data = serializer.data(with: image, original: original)  // CPU 작업
    self.diskStorage.store(value: data, forKey: key)              // 디스크 I/O
    callbackQueue.execute { completionHandler(result) }           // 완료 알림
}
```

**3. DiskStorage는 "단독으로" 사용되는 것이 아니다**

`ImageCache`의 디스크 관련 작업은 여러 단계로 구성된다:
1. 이미지 직렬화 (CacheSerializer.data())
2. 디스크에 기록 (diskStorage.store())
3. 결과 콜백 호출

이 전체 과정이 **하나의 원자적 단위**로 실행되어야 한다. ioQueue가 이 전체 흐름을 감싸므로, 직렬화와 저장 사이에 다른 작업이 끼어들 수 없다.

만약 DiskStorage 내부에만 Lock이 있으면, 직렬화와 저장 사이에 다른 작업이 끼어들 수 있어 일관성 문제가 발생할 수 있다.

**4. 결국 직렬화된 건 같지 않은가?**

"NSLock으로 보호하는 것"과 "직렬 큐로 보호하는 것"은 모두 동시 접근을 방지하여 **직렬화된 실행**을 보장한다는 점에서 동일한 목적을 가진다. 그러나 **방식과 성능 특성**이 다르다:

| 특성 | NSLock (동기적 보호) | ioQueue (비동기 직렬 큐) |
|------|---------------------|------------------------|
| 호출자 블로킹 | **예** (Lock 해제까지 대기) | **아니오** (즉시 반환) |
| 적합한 작업 | 빠른 인메모리 연산 | 느린 I/O, CPU 집약 작업 |
| 메인 스레드 영향 | Lock 보유 시간만큼 블로킹 | 없음 (비동기 실행) |
| 작업 단위 | 개별 연산 보호 | 복합 연산 묶음 보호 |
| 결과 전달 | 즉시 반환 가능 | 콜백/async-await 필요 |

**핵심: "직렬화"는 같지만 "블로킹 여부"가 다르다.**

NSLock은 Lock을 잡으려는 스레드를 **동기적으로 블로킹**한다. 직렬 큐는 작업을 **큐에 넣고 호출자는 즉시 반환**한다. 결과를 받는 시점은 콜백으로 분리된다.

이것이 Kingfisher가 메모리 캐시(빠른 연산, 동기 결과 필요)에는 NSLock을, 디스크 캐시(느린 I/O, 비동기 OK)에는 직렬 큐를 선택한 이유이다.

**5. 왜 DiskStorage 자체가 아닌 ImageCache에서 큐를 관리하는가?**

ImageCache가 ioQueue를 소유하는 이유는 **관심사의 분리(Separation of Concerns)** 원칙 때문이다:

- `DiskStorage.Backend`는 순수한 파일 시스템 연산만 담당한다 (값 저장, 읽기, 삭제, 만료 관리). 동시성 제어는 자신의 책임이 아니다.
- `ImageCache`는 메모리와 디스크 캐시를 조합하는 **코디네이터** 역할이다. 디스크 작업의 스케줄링과 동시성 제어는 이 레이어의 책임이다.

이렇게 분리하면 `DiskStorage`를 단위 테스트할 때 DispatchQueue 없이 동기적으로 테스트할 수 있고, 다른 컨텍스트(예: 다른 큐 전략)에서 재사용할 수도 있다.

또한 `ImageCache`의 store 메서드에서는 직렬화 → 디스크 저장 → 콜백의 전체 흐름을 하나의 ioQueue 블록 안에서 실행하므로, DiskStorage 단독으로는 보장할 수 없는 **연산 단위의 원자성**을 확보할 수 있다.

---

## 12. 요약 다이어그램

### 저장 흐름
```
store() ──────────────────────────────────────────────
   │                                                   │
   ├─ [동기] memoryStorage.storeNoThrow()               │
   │         (NSLock으로 보호)                           │
   │                                                   │
   └─ [비동기] ioQueue.async {                          │
                ├─ CacheSerializer.data()               │
                ├─ diskStorage.store()                  │
                └─ completionHandler()                  │
              }                                         │
───────────────────────────────────────────────────────
```

### 조회 흐름
```
retrieveImage() ─────────────────────────────────────────
   │                                                      │
   ├─ [동기] memoryStorage.value() → 히트? → 반환           │
   │                                                      │
   ├─ fromMemoryCacheOrRefresh? → .none 반환               │
   │                                                      │
   └─ [비동기] ioQueue (또는 현재 큐) {                      │
                ├─ diskStorage.value()                     │
                ├─ CacheSerializer.image()                │
                ├─ backgroundDecode?                       │
                ├─ 히트? → memoryStorage에 워밍             │
                └─ completionHandler()                    │
              }                                            │
──────────────────────────────────────────────────────────
```
