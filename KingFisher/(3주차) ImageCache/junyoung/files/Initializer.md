
## 🔹 init(memoryStorage:diskStorage:)

```swift
public init(
    memoryStorage: MemoryStorage.Backend<KFCrossPlatformImage>,
    diskStorage: DiskStorage.Backend<Data>
)
```

### 설명

이 initializer는 **외부에서 구성된 스토리지를 주입받아 `ImageCache`를 완성하는 핵심 생성자**다.

### 의도

- **의존성 주입(DI)** 기반 설계
- 테스트, 커스텀 스토리지, 고급 설정을 위한 **확장 포인트**
- 나머지 모든 initializer는 결국 여기로 수렴

### 추가 포인트

- `ioQueue` 이름에 `UUID`를 붙임
    - 여러 `ImageCache` 인스턴스 간 **큐 충돌 방지**
- Notification 등록을 `@MainActor`에서 수행
    - UIKit/AppKit 요구사항 충족

---

## 🔹init(name:)

```swift
public convenience init(name: String)
```

### 설명

이 initializer는 **이름만으로 안전하게 기본 설정의 `ImageCache`를 만들기 위한 사용자 편의용 API**다.

### 핵심 의도

- 90% 사용자를 위한 **가장 쉬운 진입점**
- “이름만 다르게 한 캐시”를 빠르게 만들 수 있음

### 내부 동작

`noThrowName:` initializer로 위임하여 디스크 생성 실패로 앱이 크래시 나지 않도록

---

## 🔹init(name:cacheDirectoryURL:diskCachePathClosure:) throws

```swift
public convenience init(
        name: String,
        cacheDirectoryURL:URL?,
        diskCachePathClosure:DiskCachePathClosure?
)throws
```

### 설명

이 initializer는 **디스크 캐시 구성을 완전히 제어하면서, 실패를 호출자에게 명확히 전달하기 위한 고급 생성자**다.

### 의도

- **실패를 명시적으로 다뤄야 하는 환경** 지원
- “캐시 생성 실패 = 치명적 오류”인 경우에 적합

### 중요한 제약

- `name.isEmpty` → `fatalError`
- `"default"` 이름 사용 금지 (전역 캐시 충돌 방지)

---

## 🔹init(noThrowName:cacheDirectoryURL:diskCachePathClosure:)

```swift
convenience init(
    noThrowName name: String,
    cacheDirectoryURL: URL?,
    diskCachePathClosure: DiskCachePathClosure?
)
```

### 설명

`throws` 버전과 거의 동일하지만 **디스크 캐시 생성 실패로 앱이 크래시 나지 않도록 하기 위한,** 

**안정성 중심의 내부용 생성자**다.

### 의도

캐시는 있으면 좋고 없어도 앱이 죽으면 안 되는 컴포넌트

특히 `ImageCache.default`일반 앱 코드에서 **안정성 우선**
