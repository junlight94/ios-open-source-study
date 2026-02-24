# Actor Hopping 문제와 Kingfisher ImageCache 비교 분석

## 목차

1. [액터 홉핑(Actor Hopping)이란 무엇이고, 왜 발생하는가?](#1-액터-홉핑actor-hopping이란-무엇이고-왜-발생하는가)
2. [액터 홉핑을 최소화하기 위한 해결 방법](#2-액터-홉핑을-최소화하기-위한-해결-방법)
3. [해결 코드의 정확성 검증 — WWDC 2021 기반](#3-해결-코드의-정확성-검증--wwdc-2021-기반)
4. [Kingfisher ImageCache와의 비교 분석](#4-kingfisher-imagecache와의-비교-분석)

---

## 1. 액터 홉핑(Actor Hopping)이란 무엇이고, 왜 발생하는가?

### 1-1. 액터(Actor)의 기본 동작 원리

Swift의 `actor`는 내부 상태(프로퍼티)에 대한 동시 접근을 직렬화(serialize)하여 데이터 레이스를 방지하는 동시성 프리미티브다. 각 actor는 자신만의 **직렬 실행기(serial executor)** 를 갖고 있으며, actor의 메서드가 호출될 때 해당 executor 위에서 실행된다.

```
[Actor A의 executor] ──── 작업 1, 작업 2, 작업 3 ... (직렬 실행)
[Actor B의 executor] ──── 작업 1, 작업 2, 작업 3 ... (직렬 실행)
```

### 1-2. 액터 홉핑의 정의

**액터 홉핑(Actor Hopping)** 이란, 하나의 비동기 작업 흐름 내에서 서로 다른 actor의 executor 간에 실행 컨텍스트가 반복적으로 전환되는 현상이다.

```
[ImageCache actor] → await → [DiskStorage actor] → await → [ImageCache actor] → await → [MemoryStorage actor] → ...
```

매번 `await`을 통해 다른 actor의 메서드를 호출할 때마다 현재 스레드를 놓고(suspend), 대상 actor의 executor에서 다시 실행을 재개(resume)하는 **컨텍스트 스위칭**이 발생한다.

### 1-3. 문제가 되는 코드 분석 (액터 홉핑 문제 버전)

문제 프로젝트의 구조를 살펴보면:

```swift
// ImageCache (원본명: ImageDatabase) — actor
actor ImageCache {
    private let memoryStorage = MemoryStorage()  // ← 별도의 actor (원본명: ImageDownloader)
    private let diskStorage = DiskStorage()      // ← 별도의 actor
    // ...
}

// DiskStorage — 별도의 actor
actor DiskStorage {
    func read(name: String) throws -> Data { ... }
    func write(_ data: Data, name: String) throws { ... }
    func savedFiles() throws -> [URL] { ... }
}

// MemoryStorage (원본명: ImageDownloader) — 별도의 actor
// 메모리 캐시 + 네트워크 다운로드를 겸하고 있음
actor MemoryStorage {
    private(set) var cache: [String: DownloadState] = [:]
    func image(from url: String) async throws -> UIImage { ... }
    func add(with image: UIImage, forURL url: String) { ... }
}
```

세 개의 독립된 actor(`ImageCache`, `DiskStorage`, `MemoryStorage`)가 존재한다. `ImageCache.image(from:)` 메서드의 실행 흐름을 추적해보면:

```swift
// ImageCache actor 내부
func image(from url: String) async throws -> UIImage {
    // ① ImageCache actor에서 실행 시작

    let keys = await memoryStorage.cache.keys
    // ② → MemoryStorage actor로 홉 (컨텍스트 스위칭 #1)
    // ③ → 다시 ImageCache actor로 복귀 (컨텍스트 스위칭 #2)

    if keys.contains(url) {
        return try await memoryStorage.image(from: url)
        // ④ → MemoryStorage actor로 홉 (컨텍스트 스위칭 #3)
        // ⑤ → 다시 ImageCache actor로 복귀 (컨텍스트 스위칭 #4)
    }

    let data = try await diskStorage.read(name: fileName)
    // ⑥ → DiskStorage actor로 홉 (컨텍스트 스위칭 #5)
    // ⑦ → 다시 ImageCache actor로 복귀 (컨텍스트 스위칭 #6)

    await memoryStorage.add(with: image, forURL: url)
    // ⑧ → MemoryStorage actor로 홉 (컨텍스트 스위칭 #7)
    // ⑨ → 다시 ImageCache actor로 복귀 (컨텍스트 스위칭 #8)

    // ...
}
```

**하나의 이미지를 가져오는 작업에서 최대 8번 이상의 컨텍스트 스위칭이 발생한다.**

### 1-4. 왜 이것이 성능 문제인가?

1. **컨텍스트 스위칭 비용**: 각 actor 전환은 현재 실행을 일시 중단하고, 새로운 executor에서 재개하는 과정을 포함한다. 이는 스레드 전환, 스택 저장/복원 등의 오버헤드를 수반한다.

2. **스레드 포화(Thread Starvation)**: Swift의 cooperative thread pool은 CPU 코어 수만큼의 스레드만 유지한다. 수백 개의 이미지를 동시에 로딩할 때, 각 요청마다 여러 actor 간의 홉핑이 발생하면 대기 중인 작업들이 쌓이며 스레드 풀이 포화될 수 있다.

3. **불필요한 직렬화**: `DiskStorage`가 별도의 actor이므로, `ImageCache`에서 디스크 I/O를 요청할 때마다 `DiskStorage`의 executor에서 실행 순서를 기다려야 한다. 하지만 실제로 `DiskStorage`의 상태(folder 프로퍼티 등)는 초기화 이후 거의 변하지 않으므로, 별도의 actor로 분리하여 보호할 필요성이 낮다.

---

## 2. 액터 홉핑을 최소화하기 위한 해결 방법

### 2-1. 핵심 아이디어: Global Actor로 통합

해결의 핵심은 **논리적으로 하나의 동시성 도메인에 속하는 객체들을 하나의 actor executor에서 실행되도록 통합**하는 것이다.

`ImageCache`를 `@globalActor`로 승격시키고, `DiskStorage`를 별도의 actor 대신 `@ImageCache`로 격리(isolate)시키면, 두 객체가 같은 executor를 공유하게 된다.

### 2-2. 해결 코드의 변경 사항

**Before (문제 코드):**

```swift
// DiskStorage.swift
actor DiskStorage {   // ← 별도의 actor (자신만의 executor를 가짐)
    func read(name: String) throws -> Data { ... }
    func write(_ data: Data, name: String) throws { ... }
}

// ImageCache.swift (원본명: ImageDatabase)
actor ImageCache {
    private let diskStorage = DiskStorage()  // ← 별도 actor의 인스턴스
}
```

**After (해결 코드):**

```swift
// DiskStorage.swift
@ImageCache                  // ← ImageCache의 global actor로 격리
class DiskStorage {           // ← actor가 아닌 일반 class
    func read(name: String) throws -> Data { ... }
    func write(_ data: Data, name: String) throws { ... }
}

// ImageCache.swift (원본명: ImageDatabase)
@globalActor                  // ← global actor로 승격
actor ImageCache {
    static let shared = ImageCache()
    private var diskStorage: DiskStorage!

    func setupInitialData() async throws {
        diskStorage = await DiskStorage()  // ← 같은 actor 컨텍스트에서 초기화
    }
}
```

### 2-3. 변경 후 실행 흐름

```swift
// ImageCache actor 내부
func image(from url: String) async throws -> UIImage {
    // ① ImageCache actor에서 실행 시작

    let keys = await memoryStorage.cache.keys
    // ② → MemoryStorage actor로 홉 (컨텍스트 스위칭 #1)
    // ③ → 다시 ImageCache actor로 복귀 (컨텍스트 스위칭 #2)

    let data = try await diskStorage.read(name: fileName)
    // ✅ DiskStorage는 @ImageCache이므로 같은 executor에서 실행!
    // ✅ 컨텍스트 스위칭 없음!

    await memoryStorage.add(with: image, forURL: url)
    // ④ → MemoryStorage actor로 홉 (컨텍스트 스위칭 #3)
    // ⑤ → 다시 ImageCache actor로 복귀 (컨텍스트 스위칭 #4)
}
```

**컨텍스트 스위칭이 8번에서 4번으로 절반 가까이 줄어든다.** `DiskStorage`와의 모든 상호작용에서 홉핑이 제거되었기 때문이다.

### 2-4. `@globalActor`가 해결하는 원리

```
[Before]
ImageCache executor  ──┬── 작업 A
                       └── (await) ──→ DiskStorage executor ──→ 작업 B ──→ (return) ──→ ImageCache executor

[After]
ImageCache executor  ──┬── 작업 A
                       └── 작업 B (DiskStorage도 여기서 실행)
```

`@ImageCache`를 붙인 `DiskStorage`의 모든 메서드는 `ImageCache` actor의 executor에서 실행된다. 따라서 `ImageCache` 내부에서 `DiskStorage`의 메서드를 호출할 때 executor 전환이 발생하지 않는다.

> **주의**: `DiskStorage`의 `fileName(for:)` 메서드는 `nonisolated static`으로 선언되어 있다. 이 메서드는 actor의 상태에 접근하지 않으므로, 어떤 executor에서든 자유롭게 호출할 수 있다. 이렇게 상태에 접근하지 않는 순수 함수는 `nonisolated`로 선언하여 불필요한 동기화를 피하는 것이 좋다.

---

## 3. 해결 코드의 정확성 검증 — WWDC 2021 기반

### 3-1. WWDC 2021 "Protect mutable state with Swift actors" 세션

이 해결 방식은 **WWDC 2021의 "Protect mutable state with Swift actors" (세션 10133)** 에서 소개된 패턴이다. Apple은 이 세션에서 다음과 같이 설명했다:

> "When you have multiple actors that work closely together, consider consolidating them into a single actor or using a global actor to reduce hopping."

세션에서 제시된 예제도 이미지 다운로더/캐시 시나리오로, 본 프로젝트와 매우 유사한 구조다.

### 3-2. 해결 방식의 정당성

| 판단 기준 | 평가 |
|-----------|------|
| `DiskStorage`는 독립적으로 동시 접근을 보호해야 하는가? | **아니다.** `ImageCache`를 통해서만 접근되므로 독립적 보호가 불필요하다. |
| `DiskStorage`의 메서드가 `ImageCache` 외부에서 호출되는가? | **아니다.** `DiskStorage`는 `ImageCache`의 `private` 프로퍼티다. |
| 두 객체의 상태가 논리적으로 결합되어 있는가? | **그렇다.** `savedURLs` Set과 디스크의 실제 파일 목록은 항상 동기화되어야 한다. |

위 세 가지 조건을 모두 충족하므로, `DiskStorage`를 `ImageCache`의 global actor로 통합하는 것은 올바른 설계 판단이다.

### 3-3. 한 가지 주의점: MemoryStorage는 왜 통합하지 않았는가?

`MemoryStorage`(원본명: `ImageDownloader`)는 여전히 별도의 actor로 유지한다. 이유는 다음과 같다:

1. **네트워크 I/O 특성**: `MemoryStorage`는 캐시 미스 시 `URLSession`을 통해 네트워크 요청을 수행한다. 네트워크 요청은 `await` 시점에서 일시 중단되며, 완료까지 수 초가 걸릴 수 있다. 만약 `ImageCache`와 통합하면, 네트워크 요청을 기다리는 동안에도 `ImageCache` executor가 점유되어, 캐시 조회나 디스크 읽기 같은 빠른 작업들이 대기하게 된다.

2. **독립적 상태 관리**: `MemoryStorage`의 `cache` 딕셔너리는 다운로드 상태(`.loading`, `.completed`, `.failed`)를 관리하며, 이는 디스크 스토리지와는 독립적인 생명주기를 가진다.

3. **재사용 가능성**: `MemoryStorage`는 `ImageCache` 외부에서도 독립적으로 사용될 수 있는 범용적인 컴포넌트다.

**결론: 긴밀하게 결합된 하위 컴포넌트(DiskStorage)는 global actor로 통합하고, 독립적인 컴포넌트(MemoryStorage)는 별도 actor로 유지하는 것이 올바른 방식이다.**

---

## 4. Kingfisher ImageCache와의 비교 분석

### 4-1. Kingfisher의 전체 아키텍처

Kingfisher의 `ImageCache`는 actor를 사용하지 않고, **GCD(Grand Central Dispatch) 기반의 전통적인 동시성 모델**을 사용한다.

```
ImageCache (open class, @unchecked Sendable)
├── memoryStorage: MemoryStorage.Backend<KFCrossPlatformImage>
│   ├── 내부: NSCache + NSLock
│   └── Thread-safe: NSLock으로 직접 보호
├── diskStorage: DiskStorage.Backend<Data>
│   ├── 내부: FileManager + DispatchQueue
│   └── Thread-safe: DispatchQueue로 간접 보호
└── ioQueue: DispatchQueue (직렬 큐)
    └── 디스크 작업 디스패치용
```

### 4-2. Kingfisher MemoryStorage의 동기화: NSLock

```swift
// Kingfisher MemoryStorage.Backend
public final class Backend<T: CacheCostCalculable>: @unchecked Sendable {
    let storage = NSCache<NSString, StorageObject<T>>()
    var keys = Set<String>()
    private let lock = NSLock()

    func storeNoThrow(value: T, forKey key: String, expiration: StorageExpiration? = nil) {
        lock.lock()
        defer { lock.unlock() }
        // NSCache에 저장 + keys Set에 추가
        storage.setObject(object, forKey: key as NSString, cost: value.cacheCost)
        keys.insert(key)
    }

    public func remove(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeObject(forKey: key as NSString)
        keys.remove(key)
    }
}
```

**왜 NSLock이 필요한가?**

`NSCache` 자체는 Apple 문서에 따르면 thread-safe하다. 그러나 Kingfisher는 `NSCache` **외에도** `keys`라는 `Set<String>` 프로퍼티를 함께 관리한다:

```swift
let storage = NSCache<NSString, StorageObject<T>>()  // thread-safe
var keys = Set<String>()                               // thread-safe하지 않음!
```

`keys`는 캐시에 어떤 키가 저장되어 있는지 추적하는 용도다. `NSCache`가 시스템 메모리 압박으로 인해 자동으로 항목을 제거(evict)할 때, `NSCache`는 delegate를 통해 알려주지만, Kingfisher는 성능상의 이유로 delegate를 사용하지 않고 `removeExpired()` 시점에 정리한다. (관련 이슈: [#1233](https://github.com/onevcat/Kingfisher/issues/1233))

따라서 `NSLock`은 `NSCache` 자체를 보호하기 위한 것이 아니라, **`NSCache`와 `keys` Set의 복합 연산(compound operation)의 원자성을 보장**하기 위한 것이다.

```swift
// 이 두 연산이 원자적이어야 한다:
storage.setObject(object, forKey: key as NSString, cost: value.cacheCost)  // 1) NSCache에 저장
keys.insert(key)                                                           // 2) keys에 추가
```

만약 Lock 없이 이 두 연산 사이에 다른 스레드가 끼어들면, NSCache에는 저장되었지만 keys에는 아직 없는 불일치 상태가 발생할 수 있다.

### 4-3. Kingfisher DiskStorage의 동기화: DispatchQueue

```swift
// Kingfisher DiskStorage.Backend
public final class Backend<T: DataTransformable>: @unchecked Sendable {
    private let propertyQueue = DispatchQueue(label: "...propertyQueue")
    let metaChangingQueue: DispatchQueue
    let maybeCachedCheckingQueue = DispatchQueue(label: "...maybeCachedCheckingQueue")
    // ...
}
```

```swift
// ImageCache에서 디스크 작업은 ioQueue를 통해 실행
private let ioQueue: DispatchQueue

open func store(_ image: ...) {
    // 메모리 저장은 동기적으로 바로 실행
    memoryStorage.storeNoThrow(value: image, forKey: computedKey, ...)

    // 디스크 저장은 ioQueue에서 비동기적으로 실행
    ioQueue.async {
        self.syncStoreToDisk(data, forKey: key, ...)
    }
}
```

**DiskStorage에 NSLock이 없는 이유:**

`DiskStorage` 자체에는 NSLock이 없다. 대신 `ImageCache`의 **`ioQueue`(직렬 DispatchQueue)** 를 통해 모든 디스크 작업이 직렬화된다.

```
ioQueue (serial) ──→ [디스크 쓰기 A] → [디스크 읽기 B] → [디스크 삭제 C] → ...
```

직렬 큐 자체가 동시 접근을 막아주므로, `DiskStorage` 내부에서 별도로 Lock을 걸 필요가 없다. 이는 매우 효율적인 설계인데, 파일 I/O는 원래 느린 작업이므로 직렬 큐에서 실행해도 성능 손실이 미미하며, Lock의 오버헤드를 피할 수 있다.

`DiskStorage` 내부에서 사용하는 `propertyQueue`, `metaChangingQueue`, `maybeCachedCheckingQueue`는 각각 config 프로퍼티 접근, 파일 메타데이터 변경, 캐시 존재 여부 확인이라는 **특정 프로퍼티의 thread-safety**를 위한 것이다.

### 4-4. 두 프로젝트와 Kingfisher의 구조 비교

| 비교 항목 | 문제 코드 | 해결 코드 | Kingfisher |
|-----------|-----------|-----------|------------|
| **동시성 모델** | Swift Actor | Swift Actor + Global Actor | GCD (DispatchQueue) |
| **메모리 캐시** | actor (MemoryStorage) | actor (MemoryStorage) | NSCache + NSLock |
| **디스크 스토리지** | 별도 actor (DiskStorage) | @globalActor class (DiskStorage) | class + ioQueue |
| **이미지 조회 흐름의 컨텍스트 스위칭** | 최대 8회 | 최대 4회 | 없음 (GCD 디스패치) |
| **디스크↔컨트롤러 동기화** | actor 경계에서 await | 같은 executor에서 동기 실행 | 직렬 큐에서 동기 실행 |
| **Sendable 보장** | actor 자체가 보장 | actor + @unchecked 불필요 | @unchecked Sendable |

### 4-5. 최초 문제 코드 vs Kingfisher

**최초 문제 코드는 Kingfisher와 유사한가?**

논리적 구조는 유사하다. 둘 다 "메모리 캐시 → 디스크 캐시 → 네트워크 다운로드" 3단계 전략을 사용한다. 그러나 동시성 보호 메커니즘이 완전히 다르다.

- **문제 코드**: 세 가지 컴포넌트를 각각 독립 actor로 분리했다. actor 모델의 안전성은 보장되지만, 과도한 격리가 불필요한 홉핑을 유발한다.
- **Kingfisher**: 세 가지 컴포넌트가 모두 일반 class이며, `ImageCache`가 `ioQueue`를 통해 접근을 조율한다. 홉핑 자체가 존재하지 않는다.

### 4-6. 해결 코드 vs Kingfisher

**해결 코드는 Kingfisher와 유사한가?**

해결 코드의 `@globalActor` 패턴은 Kingfisher의 `ioQueue` 패턴과 **의미적으로 동등**하다.

| 해결 코드 | Kingfisher | 의미 |
|-----------|------------|------|
| `@globalActor actor ImageCache` | `ioQueue: DispatchQueue` | 하나의 직렬 실행 컨텍스트 |
| `@ImageCache class DiskStorage` | `DiskStorage.Backend` + `ioQueue.async { ... }` | 해당 컨텍스트에서 실행 |
| `ImageCache` 내에서 `diskStorage.read()` 직접 호출 | `ioQueue.async { self.diskStorage.value(...) }` | 같은 직렬 컨텍스트 내 실행 |

둘 다 "디스크 스토리지 접근을 하나의 직렬 실행 컨텍스트로 통합"하는 같은 전략을 사용한다. 차이는 그 직렬 컨텍스트가 **actor executor**인지 **DispatchQueue**인지일 뿐이다.

### 4-7. Kingfisher를 Actor 방식으로 바꾸면?

만약 Kingfisher의 `ImageCache` 시스템을 Swift Actor 모델로 재설계한다면, 다음과 같은 형태가 될 것이다:

```swift
// Step 1: ImageCache를 globalActor로 정의
@globalActor
actor ImageCacheActor {
    static let shared = ImageCacheActor()
}

// Step 2: DiskStorage를 ImageCacheActor로 격리
@ImageCacheActor
class DiskStorageBackend {
    private let fileManager = FileManager.default
    private let directoryURL: URL
    private var maybeCached: Set<String>?

    func store(value: Data, forKey key: String) throws {
        // ioQueue.async 없이 직접 실행 — 같은 actor executor에서 실행됨
        let fileURL = cacheFileURL(forKey: key)
        try value.write(to: fileURL, options: [])
        maybeCached?.insert(fileURL.lastPathComponent)
    }

    func value(forKey key: String) throws -> Data? {
        let fileURL = cacheFileURL(forKey: key)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }
}

// Step 3: MemoryStorage — NSCache가 이미 thread-safe이므로 nonisolated로 유지 가능
// 다만 keys Set 관리가 필요하면 별도 actor 또는 Lock 유지
final class MemoryStorageBackend: @unchecked Sendable {
    private let storage = NSCache<NSString, StorageObject>()
    private var keys = Set<String>()
    private let lock = NSLock()  // keys Set 보호용 — actor로 대체하면 오히려 홉핑 발생

    nonisolated func store(value: UIImage, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.setObject(StorageObject(value), forKey: key as NSString)
        keys.insert(key)
    }

    nonisolated func value(forKey key: String) -> UIImage? {
        storage.object(forKey: key as NSString)?.value
    }
}

// Step 4: ImageCache — globalActor에서 조율
@ImageCacheActor
class ImageCache {
    static let `default` = ImageCache()

    // nonisolated — 어디서든 동기적으로 접근 가능
    nonisolated let memoryStorage = MemoryStorageBackend()

    // @ImageCacheActor — 같은 executor에서 실행
    let diskStorage = DiskStorageBackend()

    func retrieveImage(forKey key: String) async throws -> ImageCacheResult {
        // 1) 메모리 캐시 확인 — nonisolated이므로 홉핑 없음
        if let image = memoryStorage.value(forKey: key) {
            return .memory(image)
        }

        // 2) 디스크 캐시 확인 — 같은 actor이므로 홉핑 없음!
        if let data = try diskStorage.value(forKey: key),
           let image = UIImage(data: data) {
            // 메모리에도 캐시
            memoryStorage.store(value: image, forKey: key)
            return .disk(image)
        }

        return .none
    }

    func store(_ image: UIImage, data: Data?, forKey key: String) async throws {
        // 메모리 저장 — nonisolated, 즉시 실행
        memoryStorage.store(value: image, forKey: key)

        // 디스크 저장 — 같은 actor, 홉핑 없음
        if let data = data {
            try diskStorage.store(value: data, forKey: key)
        }
    }
}
```

**핵심 변환 규칙:**

| Kingfisher 원본 | Actor 방식 변환 | 이유 |
|----------------|----------------|------|
| `ioQueue.async { ... }` | `@ImageCacheActor` 메서드 직접 호출 | ioQueue → actor executor로 대체 |
| `NSLock` (MemoryStorage) | `NSLock` 유지 또는 `Mutex` | NSCache의 keys Set 보호에는 Lock이 더 적합. actor로 바꾸면 오히려 홉핑 발생 |
| `@unchecked Sendable` | actor 격리로 자연스럽게 Sendable | actor 자체가 Sendable |
| `completionHandler` 콜백 | `async/await` 리턴 | 콜백 → structured concurrency |
| `DispatchQueue` 기반 직렬화 | actor executor 기반 직렬화 | 의미적으로 동등 |

### 4-8. MemoryStorage에 NSLock을 사용하는 것이 맞는가?

사용자의 분석이 정확하다. 정리하면:

**MemoryStorage에 NSLock이 필요한 이유:**
- `NSCache` 자체는 thread-safe하지만, Kingfisher는 `NSCache` + `keys` Set을 함께 관리한다.
- `keys` Set은 `Swift.Set` 타입으로 thread-safe하지 않다.
- 두 자료구조에 대한 복합 연산의 원자성을 보장해야 하므로 `NSLock`이 필요하다.
- Lock은 동기적이고 빠르다. 메모리 접근은 나노초 단위이므로 Lock의 오버헤드가 미미하다.

**DiskStorage에 NSLock이 불필요한 이유:**
- `ImageCache`의 `ioQueue`(직렬 DispatchQueue)가 이미 모든 디스크 접근을 직렬화한다.
- 직렬 큐 자체가 "한 번에 하나의 작업만 실행"을 보장하므로, 내부에서 추가 Lock은 불필요하다.
- 파일 I/O는 밀리초 단위의 느린 작업이므로, Lock보다 큐 기반 직렬화가 더 자연스럽다.
- `DiskStorage` 내부의 `propertyQueue`, `maybeCachedCheckingQueue` 등은 `ioQueue` 외부에서 접근될 수 있는 특정 프로퍼티를 보호하기 위한 것이지, 디스크 I/O 자체를 보호하기 위한 것이 아니다.

```
[MemoryStorage 접근 패턴]
Thread A ──→ NSLock.lock() → NSCache + keys 조작 → NSLock.unlock()
Thread B ──→ (대기) ──────→ NSLock.lock() → NSCache + keys 조작 → NSLock.unlock()
→ 동기적 접근이므로 Lock이 적합

[DiskStorage 접근 패턴]
ImageCache ──→ ioQueue.async { diskStorage.store(...) }
ImageCache ──→ ioQueue.async { diskStorage.value(...) }  ← 앞 작업이 끝난 후 실행
→ 비동기 직렬화이므로 Queue가 적합
```

---

## 5. 요약

| 질문 | 답변 |
|------|------|
| **액터 홉핑은 왜 발생하나?** | 서로 다른 actor의 메서드를 호출할 때마다 executor 전환(컨텍스트 스위칭)이 발생한다. 문제 코드에서는 ImageCache, DiskStorage, MemoryStorage가 각각 별도의 actor이므로, 하나의 이미지를 가져오는 과정에서 최대 8번의 홉핑이 발생한다. |
| **해결 방법은?** | `@globalActor`를 사용하여 논리적으로 결합된 컴포넌트(ImageCache + DiskStorage)를 같은 executor에서 실행되도록 통합한다. 독립적인 컴포넌트(MemoryStorage)는 별도 actor로 유지한다. |
| **이 해결 방식이 맞는가?** | WWDC 2021 "Protect mutable state with Swift actors" 세션에서 소개된 패턴과 정확히 일치한다. |
| **Kingfisher와의 차이점은?** | Kingfisher는 actor 대신 GCD(DispatchQueue + NSLock)를 사용한다. 그러나 "디스크 접근을 하나의 직렬 컨텍스트로 통합"하는 핵심 전략은 해결 코드의 `@globalActor` 패턴과 의미적으로 동등하다. |
| **MemoryStorage의 NSLock은 왜 필요한가?** | NSCache + keys Set의 복합 연산 원자성 보장을 위해 필요하다. NSCache 자체는 thread-safe하지만 keys Set은 아니다. |
| **DiskStorage에 NSLock이 없는 이유는?** | ImageCache의 ioQueue(직렬 큐)가 이미 모든 디스크 접근을 직렬화하므로, 내부 Lock이 불필요하다. |

---

## 참고 자료

- [WWDC 2021 - Protect mutable state with Swift actors](https://developer.apple.com/videos/play/wwdc2021/10133/)
- [WWDC 2021 - Swift concurrency: Behind the scenes](https://developer.apple.com/videos/play/wwdc2021/10254/)
- [Kingfisher GitHub - Issue #1233](https://github.com/onevcat/Kingfisher/issues/1233)
- [Swift Evolution - SE-0313: Improved control over actor isolation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0313-actor-isolation-control.md)
