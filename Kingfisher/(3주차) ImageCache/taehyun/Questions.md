# ImageCache.swift 학습 질문 & 답변

---


## Q1. 왜 이니셜라이저에서 `Task { @MainActor in ... }`을 사용하여 알림을 등록하는가? 그냥 `NotificationCenter.default.addObserver()`를 호출하면 안 되는가?

### 답변

사실 `NotificationCenter.default.addObserver()` 자체는 thread-safe하므로, 어떤 스레드에서든 호출할 수 있다. 그런데 여기서 `Task { @MainActor in ... }`을 쓰는 이유는 크게 두 가지가 있다:

**1. `@objc` 셀렉터 기반 옵저버의 런타임 안전성:**

등록하는 셀렉터들(`clearMemoryCache`, `cleanExpiredDiskCache`, `backgroundCleanExpiredDiskCache`)은 `@objc`로 표시된 메서드들이다. 특히 `backgroundCleanExpiredDiskCache()`는 `@MainActor`로 표시되어 있어 반드시 메인 스레드에서 실행되어야 한다.

`UIApplication` 관련 알림(`didReceiveMemoryWarning`, `didEnterBackground` 등)은 시스템에 의해 메인 스레드에서 발송되므로, 셀렉터 기반 옵저버도 메인 스레드에서 호출된다. 메인 스레드에서 등록해야 이 흐름이 보장된다.

**2. Swift Concurrency와의 호환성:**

Swift 6에서는 `@Sendable` 클로저 캡처, `@MainActor` 격리 등의 규칙이 엄격해졌다. `Task { @MainActor in ... }`을 사용하면 이 컨텍스트 내의 코드가 Main Actor에서 실행됨을 컴파일러에게 명시적으로 알려, 컴파일 타임에 동시성 관련 경고/에러를 방지한다.

다만 한 가지 주의할 점은, `Task { }`로 감싸면 이니셜라이저가 반환된 **이후**에 알림이 등록된다는 것이다. 이 짧은 시간 동안 알림이 발생하면 놓칠 수 있다. 하지만 실제로 `didReceiveMemoryWarning`이나 `didEnterBackground` 같은 알림은 앱 초기화 직후에 발생하지 않으므로 실용적으로 문제가 되지 않는다.

---

## Q2. `computedKey`는 왜 필요한가? 그냥 key만 사용하면 안 되는가?

### 답변

```swift
func computedKey(with identifier: String) -> String {
    if identifier.isEmpty {
        return self
    } else {
        return appending("@\(identifier)")
    }
}
```

**같은 이미지, 다른 처리 = 다른 결과물**이기 때문이다.

예를 들어, 같은 URL의 이미지를 두 가지 방식으로 사용한다고 하자:
1. 프로필 화면: 200x200 리사이징
2. 상세 화면: 원본 크기

둘 다 같은 URL(`https://example.com/avatar.jpg`)이지만, 캐시에 저장되는 이미지는 다르다:
- `"https://example.com/avatar.jpg"` → 원본 이미지
- `"https://example.com/avatar.jpg@ResizingProcessor(200x200)"` → 200x200 리사이즈된 이미지

만약 `computedKey` 없이 key만 사용한다면:
1. 프로필 화면에서 200x200으로 리사이즈한 이미지를 캐시에 저장
2. 상세 화면에서 같은 키로 캐시를 조회 → 200x200 리사이즈된 이미지를 받음 (원본이 아님!)

이런 문제를 방지하기 위해, 캐시 키에 프로세서 식별자를 포함시켜 각 처리 결과물을 독립적으로 캐싱한다.

`@` 구분자를 사용하는 것은 단순한 컨벤션이다. URL에 `@`이 포함될 수 있지만, 프로세서 식별자가 빈 문자열이면 `@`이 추가되지 않으므로 기본 동작에 영향을 주지 않는다.

---

## Q3. `store()` 메서드에서 메모리 저장은 즉시 수행하고, 디스크 저장은 비동기로 수행하는 이유는 무엇인가?

### 답변

이 비대칭적 설계는 **성능 최적화**와 **사용자 경험** 관점에서 합리적이다.

**메모리 저장이 즉시 수행되는 이유:**

1. **속도**: NSCache에 객체를 저장하는 것은 해시 테이블에 포인터를 넣는 연산이므로 마이크로초 단위로 매우 빠르다.
2. **즉시 사용 가능**: 이미지를 다운로드한 직후, 같은 이미지를 또 요청하면 메모리 캐시에서 바로 가져올 수 있어야 한다. 디스크 저장이 완료될 때까지 기다리면 그 사이에 캐시 미스가 발생할 수 있다.
3. **메인 스레드 안전**: NSCache 접근 + NSLock은 매우 빠르므로 메인 스레드에서 실행해도 UI에 영향이 없다.

**디스크 저장이 비동기인 이유:**

1. **이미지 직렬화**: 이미지를 PNG/JPEG 등의 Data로 변환하는 것은 CPU 집약적인 작업이다. 큰 이미지의 경우 수십~수백 밀리초가 소요될 수 있다.
2. **파일 I/O**: 디스크에 파일을 기록하는 것은 밀리초 단위의 느린 작업이다. 플래시 저장소의 쓰기 속도, 파일 시스템 오버헤드, 파일 속성 설정 등이 모두 시간이 걸린다.
3. **메인 스레드 보호**: 이런 느린 작업을 메인 스레드에서 동기적으로 수행하면 UI가 멈춘다 (프레임 드롭, ANR).

**결론적으로:**
- 메모리 캐시: "빠르고 동기적" → 즉시 결과를 반환해야 하는 상황에 적합
- 디스크 캐시: "느리고 비동기적" → 나중에 결과를 알려주면 되는 상황에 적합

이 패턴은 "Write-Behind Cache"의 변형이라고 볼 수 있다. 메모리 캐시는 즉시 업데이트하고, 디스크 캐시는 백그라운드에서 나중에 업데이트하는 전략이다.
