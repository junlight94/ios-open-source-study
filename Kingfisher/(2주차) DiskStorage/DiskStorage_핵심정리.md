# Kingfisher DiskStorage.swift 핵심 정리

---

## 1. 캐시 경로(directoryURL) 결정 흐름

### cacheName 생성 규칙

```swift
cacheName = "com.onevcat.Kingfisher.ImageCache.\(config.name)"
```

- `config.name`이 같으면 같은 폴더를 공유하게 된다. 정책이 다른 스토리지가 동일 폴더를 쓰면 충돌 위험이 있으므로, `name`은 스토리지 단위로 고유해야 한다.

### Sandbox의 Caches 디렉토리 사용

```swift
url = config.fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
// → Library/Caches
```

- `Library/Caches`는 **purgeable**(OS가 필요 시 정리/삭제 가능)한 위치다.
- 캐시 데이터는 "재다운로드/재생성이 가능하다"는 전제하에 여기에 두는 것이 적절하다.
- 따라서 DiskStorage는:
  - 폴더가 언제든 삭제될 수 있음을 전제로 **재생성/재시도 로직**을 갖고 있다.
  - 캐시 miss를 정상 케이스로 다룬다.

### directoryURL이 `let`인 이유

저장 위치가 런타임 중 바뀌면 기존 파일의 위치/조회/정리가 꼬인다. 그래서 **폴더 경로는 초기화 시점에 결정 후 고정**한다.

> [jaeho - 2-1. 폴더명/폴더 경로 결정 흐름](https://github.com/junlight94/ios-open-source-study/tree/main/Kingfisher/(2주차)%20DiskStorage/jaeho)

---

## 2. 파일 속성(Attribute)을 메타데이터로 재해석 - 변수명과 의미가 다르다

DiskStorage는 **파일 시스템 메타데이터를 캐시 정보 저장소로 활용**하기 위해 원래 의미를 재해석한다.

| 파일 속성 | 원래 의미 | DiskStorage에서의 의미 |
|---|---|---|
| `creationDate` | 파일 생성 시각 | **마지막 접근 시각 (lastAccessDate)** |
| `modificationDate` | 파일 수정 시각 | **만료 예정 시각 (estimatedExpirationDate)** |

```swift
let attributes: [FileAttributeKey : Any] = [
    .creationDate: now.fileAttributeDate,              // 마지막 접근 시간
    .modificationDate: expiration.estimatedExpirationSinceNow.fileAttributeDate  // 만료 예정 시간
]
```

이렇게 하면 **별도의 DB나 메타데이터 파일 없이도**:
- 만료 체크
- LRU 기반 정리(접근 시각 기반)

가 가능해진다. 별도 메타데이터 파일을 만들었다면 파일 개수 2배, I/O도 2배가 되었을 것이다.

> [jaeho - Q2. 변수명과 의미를 다르게 쓴다](https://github.com/junlight94/ios-open-source-study/tree/main/Kingfisher/(2주차)%20DiskStorage/jaeho) | [jihee - 파일 시스템 속성 활용](https://github.com/junlight94/ios-open-source-study/tree/main/Kingfisher/(2주차)%20DiskStorage/jihee)

---

## 3. fileAttributeDate의 ceil(올림) 처리

```swift
var fileAttributeDate: Date {
    return Date(timeIntervalSince1970: ceil(timeIntervalSince1970))
}
```

- 메모리의 `Date`는 `TimeInterval(Double)` 기반이라 소수점 이하(0.1초 등)가 존재할 수 있다.
- 파일 속성에 기록될 때는 파일시스템/환경에 따라 정밀도가 낮아져 **소수점이 잘리거나 반올림**되어 경계가 흔들릴 수 있다.
- 그 결과 "만료가 조금 더 빨리 온 것처럼" 기록되어 테스트가 flaky해질 수 있다.

Kingfisher는 파일 속성에 기록할 Date를 항상 **올림(ceil) 처리**해서 "조기 만료" 방향의 흔들림을 방지한다.

> [jaeho - Q5. Date(TimeInterval) vs file attribute precision + ceil](https://github.com/junlight94/ios-open-source-study/tree/main/Kingfisher/(2주차)%20DiskStorage/jaeho)

---

## 4. maybeCached: false-positive 전략

### 구조

`maybeCached: Set<String>?`는 디스크에 저장된 파일명을 메모리 Set으로 관리하여, **디스크 접근 전에 빠르게 필터링**하는 역할을 한다.

```swift
// 1단계: 메모리에서 빠른 체크 O(1)
let fileMaybeCached = maybeCachedCheckingQueue.sync {
    return maybeCached?.contains(fileURL.lastPathComponent) ?? true
}
guard fileMaybeCached else { return nil }  // 확실히 없으면 디스크 접근 생략

// 2단계: 실제 디스크 확인
guard fileManager.fileExists(atPath: filePath) else { return nil }
```

### false-positive란?

| 상태 | Set | 디스크 | 결과 |
|---|---|---|---|
| True Positive | 있음 | 있음 | 정상 |
| True Negative | 없음 | 없음 | 정상 |
| **False Positive** | 있음 | 없음 | 약간의 성능 손실 (허용) |
| **False Negative** | 없음 | 있음 | 치명적 (불허) |

Kingfisher는 **False Positive는 허용**하되, **False Negative는 절대 허용하지 않는** 전략을 사용한다.

### maybeCached에서 remove하지 않는 이유

- `maybeCached`에는 `insert`만 있고 `remove`는 없다.
- 디스크에서 파일이 삭제되는 시점은 다양하고 복잡해서, 모든 순간에 삭제 로직을 넣고 Queue를 이용해 동기화하면 "빠른 체크를 위한 Set"의 의미가 사라진다.
- 앱을 껐다 켜면 `setupCacheChecking()`에서 다시 완벽해지기 때문에, 실행 중에 복잡한 동기화 로직을 넣을 필요가 없다.
- 이는 **실용적 최적화(Pragmatic Optimization)** — 완벽한 일관성 대신 적절한 수준의 정확도와 최고의 성능을 맞바꾼 전략이다.

### 이 전략이 유효한 조건

1. **비용의 비대칭성**: 디스크 확인은 비싸고 메모리 확인은 싸다.
2. **Negative 응답이 빈번**: 존재하지 않는 리소스 요청이 많을 때 효과적이다.
3. **삭제 동기화 비용 > 이득**: 삭제 시점마다 실시간 동기화하는 것보다 방치하는 편이 낫다.

> [sunny - maybeCached, false-positive 상세 분석](https://github.com/junlight94/ios-open-source-study/tree/main/Kingfisher/(2주차)%20DiskStorage/sunny) | [jaeho - Q3. false-positive / shortcut](https://github.com/junlight94/ios-open-source-study/tree/main/Kingfisher/(2주차)%20DiskStorage/jaeho)

---

## 5. Thread Safety 설계

DiskStorage는 3개의 Serial Queue로 동시성을 관리한다.

### 5-1. propertyQueue — config 접근 보호

```swift
private let propertyQueue = DispatchQueue(label: "...propertyQueue")
private var _config: Config

public var config: Config {
    get { propertyQueue.sync { _config } }
    set { propertyQueue.sync { _config = newValue } }
}
```

- `_config`(실제 저장소)와 `config`(computed property)를 분리하여 모든 접근을 Queue로 직렬화한다.
- computed property 내부에서 `self.config`를 다시 읽으면 **무한 재귀**가 발생하므로 backing store가 필수다.
- `sync`를 사용하는 이유: getter는 반드시 값을 즉시 반환해야 하므로 `async`는 불가능하다.

**Config가 struct인 이유**: Class로 하면 외부에서 참조로 들고 있다가 내부 값을 변경할 수 있어 side-effect가 발생한다. struct는 복사로 전달되므로 오직 `set`을 통해서만 설정을 변경할 수 있다.

**MemoryStorage의 Config와 비교**: MemoryStorage는 NSCache를 사용하는데, NSCache는 자체가 thread-safe하므로 별도 Queue 보호가 필요 없다.

> [sunny - config 값 관리는 왜 이렇게 하는지?](https://github.com/junlight94/ios-open-source-study/tree/main/Kingfisher/(2주차)%20DiskStorage/sunny) | [jaeho - Q4. config & _config](https://github.com/junlight94/ios-open-source-study/tree/main/Kingfisher/(2주차)%20DiskStorage/jaeho)

### 5-2. maybeCachedCheckingQueue — 읽기는 sync, 쓰기는 async

```swift
// 읽기: sync — 결과가 즉시 필요 (다음 분기에 사용)
let fileMaybeCached = maybeCachedCheckingQueue.sync {
    return maybeCached?.contains(fileURL.lastPathComponent) ?? true
}

// 쓰기: async — 결과를 기다릴 필요 없음 (언젠가 업데이트만 되면 됨)
maybeCachedCheckingQueue.async {
    self.maybeCached?.insert(fileURL.lastPathComponent)
}
```

- 읽기는 `fileMaybeCached` 값이 즉시 필요하므로 `sync`.
- 쓰기는 업데이트가 필수가 아니기 때문에(업데이트가 안 되어도 기능은 정상 작동) `async`로 성능 향상.

> [jihee - Thread Safety](https://github.com/junlight94/ios-open-source-study/tree/main/Kingfisher/(2주차)%20DiskStorage/jihee)

### 5-3. metaChangingQueue — 조회 성능을 지키는 비동기 메타 갱신

```swift
let obj = try T.fromData(data)
metaChangingQueue.async {
    meta.extendExpiration(with: self.config.fileManager, extendingExpiration: extendingExpiration)
}
return obj  // 메타 갱신을 기다리지 않고 즉시 반환
```

- 캐시 조회 시 파일 속성 갱신(`setAttributes`)은 추가 디스크 I/O다.
- 이를 동기로 처리하면 이미지 리스트에서 빠른 스크롤 시 조회마다 "읽기 + 속성 쓰기"가 함께 발생해 렌더링이 끊길 수 있다.
- 비동기로 보내면 값 반환은 빨라지고, 속성 갱신은 큐에서 순서대로 처리된다.
- LRU 기록이 몇 ms 지연되더라도, 이는 삭제 순서를 결정하는 참고 정보일 뿐 데이터 손상으로 이어지지 않는다.

> [taehyun - metaChangingQueue 설계](https://github.com/junlight94/ios-open-source-study/tree/main/Kingfisher/(2주차)%20DiskStorage/taehyun) | [leejunyoung - properties](https://github.com/junlight94/ios-open-source-study/tree/main/Kingfisher/(2주차)%20DiskStorage/leejunyoung)

---

## 6. config.cachePathBlock = nil — 순환참조 방지

```swift
let creation = Creation(config)
self.directoryURL = creation.directoryURL
// Break any possible retain cycle set by outside.
config.cachePathBlock = nil
```

`cachePathBlock`은 경로 계산용 **일회성 클로저**다. `directoryURL`이 `let`으로 고정된 이후에는 다시 쓸 일이 없다.

### 기본 구현은 안전하다

```swift
public var cachePathBlock: (@Sendable (_ directory: URL, _ cacheName: String) -> URL)! = {
    (directory, cacheName) in
    return directory.appendingPathComponent(cacheName, isDirectory: true)
}
```
캡처 0개라서 retain cycle이 생길 일이 없다.

### 문제는 사용자가 커스터마이즈할 때

```swift
// CacheManager → backend → _config → cachePathBlock → self(CacheManager) 순환!
config.cachePathBlock = { _, cacheName in
    return self.customBaseURL.appendingPathComponent(cacheName)
}
```

외부 객체를 strong capture하면 **CacheManager -> Backend -> Config -> cachePathBlock -> CacheManager** 순환 고리가 생긴다. Kingfisher는 "이미 썼고 앞으로 필요도 없으니" nil로 지워서 위험을 끊는다.

> [jaeho - Q7. cachePathBlock = nil 이유 + retain cycle 예시](https://github.com/junlight94/ios-open-source-study/tree/main/Kingfisher/(2주차)%20DiskStorage/jaeho)

---

## 7. 초기화 전략: 앱을 죽이지 않는 안전한 생성

```swift
// 외부용: 에러를 처리할 수 있는 경우
public convenience init(config: Config) throws {
    self.init(noThrowConfig: config, creatingDirectory: false)
    try prepareDirectory()
}

// 내부용: throw하지 않는 안전한 경로
init(noThrowConfig config: Config, creatingDirectory: Bool) {
    // ...
    if creatingDirectory {
        try? prepareDirectory()  // 실패해도 삼킴
    }
}
```

- 내부 전용 init은 디렉토리 생성 실패 시 에러를 삼키고 `storageReady = false`로 표시한다.
- 실제 `store`/`value` 호출 시점에서 런타임으로 실패를 알린다.
- init 단계에서 바로 throw했다면 기본 캐시 생성 실패가 곧 **앱 크래시**로 이어질 수 있다.

> [leejunyoung - initializer 분석](https://github.com/junlight94/ios-open-source-study/tree/main/Kingfisher/(2주차)%20DiskStorage/leejunyoung)

---

## 8. 에러 복구: isFolderMissing

```swift
do {
    try data.write(to: fileURL, options: writeOptions)
} catch {
    if error.isFolderMissing {
        try prepareDirectory()      // 폴더 재생성
        try data.write(to: fileURL) // 재시도
    }
}
```

`Library/Caches`는 OS가 정리하거나 사용자가 앱 데이터를 삭제하면서 사라질 수 있다. DiskStorage는 이를 **정상적인 상황**으로 간주하고, 폴더를 재생성한 뒤 1회 재시도한다.

`isFolderMissing` 판별:
- `NSCocoaErrorDomain`, code 4 ("No such file or directory")
- Underlying error: `NSPOSIXErrorDomain`, code 2 (`ENOENT`)

> [jihee - 자동 에러 복구](https://github.com/junlight94/ios-open-source-study/tree/main/Kingfisher/(2주차)%20DiskStorage/jihee) | [leejunyoung - store 메서드 분석](https://github.com/junlight94/ios-open-source-study/tree/main/Kingfisher/(2주차)%20DiskStorage/leejunyoung)

---

## 9. 만료 연장 정책: Sliding Expiration

### .cacheTime — 원래 TTL 유지

```swift
// 원래 유효기간 길이를 복원
let originalExpiration: StorageExpiration =
    .seconds(lastEstimatedExpiration.timeIntervalSince(lastAccessDate))
// 지금부터 다시 그 기간만큼 연장
attributes = [
    .creationDate: Date().fileAttributeDate,
    .modificationDate: originalExpiration.estimatedExpirationSinceNow.fileAttributeDate
]
```

자주 읽히는 캐시는 계속 살아남는 **슬라이딩 만료(Sliding Expiration)** 방식이다.

### .expirationTime — 새 만료 시간 덮어쓰기

```swift
attributes = [
    .creationDate: Date().fileAttributeDate,
    .modificationDate: expirationTime.estimatedExpirationSinceNow.fileAttributeDate
]
```

접근 시점마다 만료 정책을 강제로 재설정한다.

### .none

만료 연장 없음. `isCached()`가 이 옵션을 사용한다 — 존재 여부만 확인할 때 만료를 연장할 이유가 없기 때문이다.

> [jaeho - 3-1. 만료 연장 정책](https://github.com/junlight94/ios-open-source-study/tree/main/Kingfisher/(2주차)%20DiskStorage/jaeho) | [taehyun - 만료 연장 설명](https://github.com/junlight94/ios-open-source-study/tree/main/Kingfisher/(2주차)%20DiskStorage/taehyun)

---

## 10. LRU 기반 용량 정리 — sizeLimit/2까지 줄이는 이유

```swift
let target = config.sizeLimit / 2
while size > target, let meta = pendings.popLast() {
    size -= UInt(meta.fileSize)
    try removeFile(at: meta.url)
    removed.append(meta.url)
}
```

- 용량을 딱 `sizeLimit`까지만 맞추면, 조금만 저장해도 바로 다시 초과하게 된다.
- 그 결과 정리 작업이 너무 자주 실행되는 상황(**thrashing**)이 생긴다.
- 한 번 정리할 때 `sizeLimit/2`까지 여유 있게 줄여서 **정리 빈도를 낮춘다**.
- 정렬 기준은 `creationDate`(= 마지막 접근 시각) — 오래 안 쓴 것부터 삭제하는 LRU 방식이다.

> [taehyun - LRU 기반 용량 정리](https://github.com/junlight94/ios-open-source-study/tree/main/Kingfisher/(2주차)%20DiskStorage/taehyun) | [jihee - LRU 캐시 정책](https://github.com/junlight94/ios-open-source-study/tree/main/Kingfisher/(2주차)%20DiskStorage/jihee)

---

## 11. Backend와 Config의 역할 분리

- **Backend**: 저장/조회/삭제/정리 등 **행위(behavior)** 담당
- **Config**: 만료 기간, 용량 제한, 파일명 정책, fileManager 등 **환경 + 정책** 담당

`fileManager`가 Config에 포함된 이유도 이 원칙 때문이다 — fileManager는 "어떤 환경에서 동작할 것인가"라는 설정이지, 행위 자체가 아니다.

> [leejunyoung - Config 분석](https://github.com/junlight94/ios-open-source-study/tree/main/Kingfisher/(2주차)%20DiskStorage/leejunyoung/files)

---

## 참고: 각 스터디원 정리 링크

| 이름 | 링크 |
|---|---|
| jaeho | [README.md](https://github.com/junlight94/ios-open-source-study/tree/main/Kingfisher/(2주차)%20DiskStorage/jaeho) |
| jihee | [DiskStorage.md](https://github.com/junlight94/ios-open-source-study/tree/main/Kingfisher/(2주차)%20DiskStorage/jihee) |
| leejunyoung | [README.md + files/](https://github.com/junlight94/ios-open-source-study/tree/main/Kingfisher/(2주차)%20DiskStorage/leejunyoung) |
| sunny | [Week2_DiskStorage.md](https://github.com/junlight94/ios-open-source-study/tree/main/Kingfisher/(2주차)%20DiskStorage/sunny) |
| taehyun | [README.md](https://github.com/junlight94/ios-open-source-study/tree/main/Kingfisher/(2주차)%20DiskStorage/taehyun) |
