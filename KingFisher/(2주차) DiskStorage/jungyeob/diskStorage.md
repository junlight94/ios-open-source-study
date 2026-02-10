## 1) Config vs _config: backing store가 있는 이유

DiskStorage에는 이런 패턴이 있다:

```swift
private var _config: Config

public var config: Config {
    get { propertyQueue.sync { _config } }
    set { propertyQueue.sync { _config = newValue } }
}
```

여기서 핵심은 두 가지다.

### (1) config는 computed property라 저장 공간이 없다

Swift에서 public var config: Config { get set }처럼 구현된 프로퍼티는 값을 저장하는 게 아니라, getter/setter 로직으로 값을 제공한다.

즉, config 자체는 저장소가 아니고 창구다.

그래서 실제 저장은 _config가 한다.
→ _config가 backing store(실제 저장 프로퍼티) 역할.

### (2) config 접근을 직렬화하기 위한 “보호막” 역할도 한다

Config는 struct라 복사되긴 하지만, **문제는 읽고 쓰는 타이밍**이다.

•	한 스레드에서 config를 바꾸는 중인데
•	다른 스레드가 동시에 config를 읽으면

원치 않는 중간 상태를 보거나 레이스 가능성이 생길 수 있다.
그래서 get/set을 propertyQueue.sync로 감싸서 한 번에 한 작업만 하도록 만든다.

정리: _config는 저장 공간, config는 thread-safe하게 접근하기 위한 창구다.

⸻

## 2) storageReady가 필요한 이유 + init이 두 갈래인 이유(묶어서 보기)

DiskStorage에 이런 플래그가 있다

```swift
private var storageReady: Bool = true
```

그리고 저장/조회 시작에 항상 걸린다

```swift
guard storageReady else {
    throw .diskStorageIsNotReady(cacheURL: directoryURL)
}
```
storageReady는 디스크 캐시가 죽었을 때 앱까지 죽지 않게 하는 안전장치로 보인다

Disk 캐시는 대부분의 앱에서 필수 기능이 아니라 최적화다.

•	캐시 폴더 생성 실패

•	OS가 캐시 폴더를 정리해서 사라짐

•	파일 시스템 에러

이런 게 생겨도 앱 전체가 크래시/초기화 실패로 이어지면 너무 크다.

그래서 Kingfisher는 (추정컨대) 디스크 캐시가 문제가 생기면

•	디스크 캐시만 비활성화하고

•	이후 접근은 빠르게 에러로 막아버리는 구조를 택한 것으로 보인다.

이 설계는 init이 throws vs best-effort로 나뉜 이유와 연결된다

```swift
public convenience init(config: Config) throws {
    self.init(noThrowConfig: config, creatingDirectory: false)
    try prepareDirectory()
}
```
```swift
init(noThrowConfig config: Config, creatingDirectory: Bool) {
    ...
    if creatingDirectory {
        try? prepareDirectory()
    }
}
```
**convenience init(throws)**

→ 외부에서 내가 직접 스토리지를 만든다”면 실패를 명확히 알리고 싶을 수 있음
→ 그래서 try prepareDirectory()로 실패를 올려준다.

**init(noThrow..., try?)**

→ 내부에서 기본 캐시를 구성하는 과정”에서 폴더 생성 실패가 앱 전체에 치명적이길 원치 않을 수 있음
→ 에러는 삼키되(try?), 대신 storageReady=false로 남겨서 이후 store/value를 막는다.

즉 둘은 이렇게 역할이 갈리는 느낌이다

실패를 밖으로 알릴 것인가(throws) vs 실패해도 내부적으로 캐시만 죽일 것인가(best-effort)

⸻

## 1) expiration: store에서 체크하는 건 뭐고, value에서 “키별 만료”는 어떻게 아는가?

여기서 제일 헷갈리는 지점이 보통 이거다:

store는 새로 저장하는 건데, 왜 expiration.isExpired를 체크하지?
value는 기존 데이터를 읽지도 않는데, 어떻게 만료를 판단하지?

이건 **만료 정보가 어디에 저장되는가**를 알면 풀린다.

⸻

### (1) store에서 expiration.isExpired는 기존 파일의 만료가 아니다

store 초반
```swift
let expiration = expiration ?? config.expiration
guard !expiration.isExpired else { return }
```
여기서 expiration은
	•	이번 저장 호출에서 전달받은 expiration (옵션)
	•	없으면 config의 기본 expiration

즉 **이번에 저장될 아이템에 적용할 만료 정책**이다.

그런데 이 만료 정책 자체가 이미 만료된 값일 수도 있다. 예를 들면

•	호출자가 즉시 만료를 의도했거나

•	TTL이 0에 가까운 값이거나

•	내부 로직상 이미 만료로 간주되는 케이스

그런 경우엔 저장해봤자 바로 무효이므로 불필요한 디스크 write를 안 하려는 방어 코드로 이해할 수 있다.

핵심: 이 시점엔 기존 파일 만료 여부를 볼 이유가 없다. 어차피 쓰면 덮어쓰기니까.

⸻

### (2) 그럼 “키별 만료 시각”은 어디에 저장되나? → 파일 메타데이터

store 후반에 이런 코드가 있다
```swift
let attributes: [FileAttributeKey: Any] = [
    .creationDate: now, // last access 용도
    .modificationDate: expirationDate // 만료 시각 용도
]
try fileManager.setAttributes(attributes, ofItemAtPath: fileURL.path)
```
여기서 중요한 사실:
	•	이 attributes는 스토리지 전체에 기록되는 게 아니라
	•	fileURL.path에 해당하는 그 파일 하나에 기록된다.

즉, “key → fileURL(파일)”로 저장된 결과물은
	•	파일 내용: 실제 이미지 데이터
	•	파일 메타: 만료 시각(modificationDate), 마지막 접근(creationDate)

를 갖게 된다.

⸻

### (3) value는 그래서 “데이터를 읽기 전에” 메타만 보고 만료를 판단할 수 있다

value에서는 key로 fileURL을 만든 뒤, 파일의 resourceValues를 읽는다

```swift
let resourceKeys: Set<URLResourceKey> = [
    .contentModificationDateKey, // 만료 시각
    .creationDateKey             // last access
]
meta = try FileMeta(fileURL: fileURL, resourceKeys: resourceKeys)

if meta.expired(referenceDate: referenceDate) {
    return nil
}
```

그래서 기존 데이터(이미지)를 먼저 로드해서 만료를 확인하는 게 아니라,
파일 메타데이터에 저장된 만료 시각으로 바로 판정한다.
이게 가능한 이유는 store 단계에서 이미 파일 메타에 만료 시각을 새겨두기 때문이다.

⸻

## 4) DiskStorage는 왜 MemoryStorage처럼 전체 lock이 없나?

MemoryStorage는 NSLock으로 거의 전체를 감싸는데
DiskStorage는 lock이 없어 보인다. 그러면 데이터 레이스를 어떻게 막지?

여기서 중요한 관점은 무엇을 보호해야 하는가?가 둘이 다르다

⸻

MemoryStorage가 lock을 크게 거는 이유

MemoryStorage는 내부에 이런 게 있다
	•	keys = Set<String>() (NSCache 밖에서 별도로 관리하는 상태)
	•	NSCache는 시스템 정책으로 자동 evict가 일어날 수 있음
	•	그러면 keys와 NSCache 내부 상태가 어긋날 수 있음

그래서 MemoryStorage는
	•	storage 조작 + keys 조작을 함께 묶어서
	•	한 번에 처리하려는 구조가 되고
	•	lock 범위가 커질 수밖에 없다.

⸻

DiskStorage는 공유 메모리 상태가 상대적으로 작다

DiskStorage에서 진짜 캐시 데이터는 메모리 변수가 아니라 파일 시스템이다.

그럼 DiskStorage에서 레이스가 나는 지점은 주로
	1.	config (읽고/쓰는 타이밍 경쟁)
	2.	maybeCached: Set<String>? (Set은 thread-safe가 아님)
	3.	파일 메타 변경(동시에 attribute 변경하면 충돌 가능)

Kingfisher는 이 공유 메모리 상태들만 딱 골라서 큐로 보호한다
	•	config: propertyQueue.sync로 직렬화
	•	maybeCached: maybeCachedCheckingQueue로 직렬화
	•	메타 변경: metaChangingQueue.async로 직렬화

즉 전체를 lock으로 감싸는 게 아니라 레이스가 생기는 공유 상태만 좁게 잠그는 방식을 택한 것으로 보인다.

⸻

**그럼 파일 write/read 자체는 직렬화 안 해도 되나?**

•	파일 I/O까지 전부 한 lock으로 감싸면 병목이 커질 수 있다.  
•	특히 서로 다른 key는 서로 다른 파일에 쓰니까, 병렬성이 성능상 유리할 수 있다   
•	캐시는 “정확성 100%”보다 “성능/복원력”이 더 중요한 경우가 많다.  

그래서 DiskStorage는 전체 I/O를 하나로 묶기보다,  
•	필요한 최소 공유 상태만 직렬화하고,    
•	파일 I/O는 시스템에 맡기는 방향을 택했을 가능성이 있다.   

요약하면: DiskStorage는 lock을 안 건다가 아니라 전체를 안 잠그고, 필요한 부분만 잠근다에 가깝다.

⸻

한 줄 결론

•	_config는 진짜 저장소(backing store), config는 thread-safe 창구.

•	storageReady + init 분기는 “디스크 캐시 실패가 앱 전체에 치명적이지 않게” 하기 위한 장치로 보임.

•	expiration은 config에만 있는 게 아니라 “각 파일의 메타데이터”에 기록됨 → 그래서 value는 메타만 보고 만료 판단 가능.

•	DiskStorage는 전체 lock 대신 config/Set/메타 변경 등 공유 상태만 선택적으로 직렬화함.