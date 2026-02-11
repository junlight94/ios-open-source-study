
## 🔹 createMemoryStorage()

```swift
private static func createMemoryStorage() -> MemoryStorage.Backend<KFCrossPlatformImage>
```

### 설명

`createMemoryStorage()`는 **시스템 전체 메모리의 1/4를 기준으로 한** 

**보수적인 기본 cost 제한을 적용해, 안정성과 캐시 효율의 균형을 맞춘 메모리 캐시를 생성한다.**

```swift
let totalMemory = ProcessInfo.processInfo.physicalMemory
let costLimit = totalMemory / 4
```

### 핵심 의도

메모리 캐시는 너무 작으면 효과 없고 

반대로 너무 크면 시스템 메모리 압박 → OS에 의해 강제 정리

그래서 **전체 물리 메모리의 1/4**라는 보수적이면서도 실용적인 기준 선택

**시스템 전체 안정성을 해치지 않는 선에서 캐시 효과 극대화**

### 중요한 설계 포인트

`physicalMemory`는 사용 가능 메모리가 아니라 **장치 스펙 기준**

실제 사용 중 메모리 상황은 eviction 정책 + 시스템 memory warning에 맡김

### `Int.max` 가드의 의미

```swift
(costLimit > Int.max) ? Int.max : Int(costLimit)
```

64bit 환경에서 `UInt64 → Int` 변환 오버플로 방지, 극단적인 환경에서도 **안전한 초기화 보장**

---

## 🔹createConfig(name:cacheDirectoryURL:diskCachePathClosure:)

```swift
private static func createConfig(...) -> DiskStorage.Config
```

### 설명

`createConfig(...)`는 **디스크 캐시의 기본 설정을 일관되게 구성하면서,**

**경로 생성 전략만 선택적으로 커스터마이즈할 수 있게 분리한 설정 팩토리**다.

### 핵심 의도

> **“기본은 관대하게, 정책은 나중에”**
> 

디스크 캐시 설정 생성을 한 곳에 모아 initializer 복잡도 감소 및 설정 일관성 유지

기본적으로 `sizeLimit = 0` (무제한), 디렉토리는 시스템 기본 위치 사용

### `diskCachePathClosure`의 역할

```swift
if let closure = diskCachePathClosure {
    diskConfig.cachePathBlock = closure
}
```

파일 경로 생성 로직을 기본 구현 대신 사용자 정의 전략으로 교체 가능

이 메서드는 DiskStorage를 생성하지 않고, **설정만 책임진다.**

실제 디렉토리 생성/검증은 DiskStorage 초기화 시점에 수행
