## propertyQueue

여기서 사용하는 `propertyQueue` 는 Config의 상태를 원자적으로 읽고 쓸 때만 사용하고 있음.

객체 전체를 보호하기 위한 상태 보호용 큐가 아닌 Config라는 Value를 원자적으로 교체하기 위한 장치

```swift
DispatchQueue(label: "com.onevcat.kingfisher.DiskStorage.Backend.propertyQueue")
```

---

## _config

Config 캡슐화 (동기화 전제 하에서만 접근 가능한 실제 저장소)

```swift
private var _config: Config
```

---

## config

propertyQueue로 원자성을 보장해서 읽고, 쓰기에 안전한 외부로 노출되어있는 config

```swift
public var config: Config {
    get { propertyQueue.sync { _config } }
    set { propertyQueue.sync { _config = newValue } }
}
```

---

## directoryURL

생성 단계에서 초기화되고 불변한 디렉토리 주소

```swift
**public** **let** directoryURL: URL
```

---

## metaChangingQueue

<aside>
💡

`metaChangingQueue`는 캐시 hit을 느리게 만들지 않기 위해, 파일 메타데이터 갱신을 “비동기(async)”로 미루는 전용 시리얼 큐

`value(forKey:)`에서 **캐시를 읽은 직후** 실행됩니다.

</aside>

캐시된 객체를 반환하는 과정은 막지 않기 위해, 객체는 즉시 리턴하고

캐시 파일의 메타데이터(접근 시간/만료 시간) 갱신은 내부적으로 직렬, 비동기 큐에서 처리해 성능을 최적화한다.

```swift
let metaChangingQueue: DispatchQueue
```

---

## maybeCached

<aside>
💡

“디스크에 없을 게 확실한 요청”을 디스크 접근 전에 메모리에서 즉시 컷하는 필터 역할

</aside>

1. `setupCacheChecking`에서 FileManager에 있는 캐싱 데이터를 읽어서 저장
2. store(저장) 성공시 `maybeCached`에 저장
3. value에서 값을 가져올 때 먼저 `maybeCached`를 체크해서 없다면 바로 리턴 (FileManager 읽기 비용 최적화)

```swift
**var** maybeCached : Set<String>?
```

---

## maybeCachedCheckingQueue

<aside>
💡

`maybeCached` 접근을 보호하는 **전용 시리얼 큐**

Set은 Thread-safe가 아니기 때문에

</aside>

```swift
DispatchQueue(label: "com.onevcat.Kingfisher.maybeCachedCheckingQueue")
```

---

## storageReady

<aside>
💡

런타임 보호용 플래그

</aside>

생성자는 기본적으로 throw하지 않고 객체를 만든 뒤, `prepareDirectory`에서 디렉토리 생성에 실패하면

`storageReady = false`로 표시해 두고, 실제 `store` / `value` 사용 시점에서 에러를 던져 막는다.

만약 init 단계에서 바로 throw했다면 기본 캐시 생성 실패가 곧 앱 크래시로 이어질 수 있기 때문이라고 생각

```swift
**private** **var** storageReady: Bool = **true**
```
