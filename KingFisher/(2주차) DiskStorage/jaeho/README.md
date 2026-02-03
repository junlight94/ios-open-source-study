# 2주차-DiskStorage

## **1) 전반적인 DiskStorage 구조 / 역할**

### **1-1. DiskStorage의 역할(한 문장)**

- DiskStorage는 **key(문자열) → 디스크 파일 1개**로 매핑해서, 캐시 데이터를 **파일로 저장/조회/정리(만료·용량)** 하는 디스크 캐시 엔진이다.

### **1-2. 구성 요소(타입) 지도**

- **`DiskStorage (enum)`**: **네임스페이스**(타입 묶음)
- **`DiskStorage.Backend<T>`**: 실제 디스크 캐시 **저장/조회/삭제/정리** 담당
- `DiskStorage.Config`: 캐시 정책(만료·용량·파일명 규칙·경로 결정) 보관
- `DiskStorage.Creation`: Config로부터 최종 캐시 폴더(directoryURL) 계산
- **`DiskStorage.FileMeta`**: 파일 메타데이터(접근 시각/만료 시각/파일 크기/디렉토리 여부) 해석
- **`Error.isFolderMissing`**: 캐시 폴더가 통째로 삭제된 경우를 감지하는 보조 로직

### **1-3. 디스크 캐시의 기본 철학**

- 디스크 캐시는 “정확한 저장소(DB)”가 아니라 **best-effort 캐시**다.
- 따라서 **캐시 폴더/파일이 언제든 사라질 수 있음**을 전제로 방어 코드를 둔다.
    - 폴더가 삭제되면 재생성 후 재시도
    - 초기화 실패 시 크래시 대신 “not ready” 상태로 에러 반환

---

## **2) 데이터 흐름, 에러 처리**

### **2-1. 폴더명/폴더 경로(directoryURL) 결정 흐름**

**(1) 루트 디렉토리 선택**

- Config.directory가 있으면 그 경로를 루트로 사용
- 없으면 기본으로 `앱 샌드박스의 Caches 디렉토리`를 사용
    - fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    - 의미: “이 앱의 Library/Caches 위치”

**(2) cacheName 생성 규칙**

- cacheName = "com.onevcat.Kingfisher.ImageCache.\(config.name)"

**(3) 최종 폴더 URL 생성**

- directoryURL = config.cachePathBlock(rootURL, cacheName)
- 기본 cachePathBlock은 rootURL / cacheName/ 형태

**(4) 왜 directoryURL은 let으로 고정?**

- 저장 위치가 런타임 중 바뀌면 “기존 파일 위치/조회/정리”가 꼬인다.
- 그래서 **폴더 경로는 초기화 시점에 결정 후 고정**하는 게 안전하다.

---

### **2-2. 파일명 결정 흐름(해시/확장자)**

**(1) 파일명 베이스(baseName)**

- usesHashedFileName == true면 baseName = sha256(key)
- 아니면 baseName = key

**(2) 확장자 결정 우선순위**

1. forcedExtension (store/value에서 강제)
2. config.pathExtension
3. (옵션) usesHashedFileName && autoExtAfterHashedFileName == true면 key에서 확장자를 추론해 붙임

**(3) 최종 파일 경로**

- fileURL = directoryURL.appendingPathComponent(fileName)

---

### **2-3. 저장(store) 흐름 + 에러 처리**

**(1) storageReady 체크**

- 초기화 중 폴더 생성 실패하면 storageReady = false
- **이후 store/value에서 diskStorageIsNotReady 에러로 방어 (크래시 방지)**

**(2) 만료 정책 적용**

- expiration이 이미 만료 상태면 “저장할 필요 없음” → return

**(3) 값 → Data 직렬화**

- T: DataTransformable의 toData() 사용
- 실패 시 cannotConvertToData 에러

**(4) 파일 쓰기**

- data.write(to: fileURL, options: writeOptions)
- 실패 시:
    - 폴더가 통째로 삭제된 케이스(isFolderMissing)면:
        1. prepareDirectory()로 폴더 재생성
        2. 다시 write 재시도
    - 그래도 실패하면 cannotCreateCacheFile 에러

**(5) 파일 속성(attribute) 기록 (핵심)**

- DiskStorage는 **파일 속성으로 만료/접근 정보를 저장**한다.
    - .creationDate → “마지막 접근 시각(lastAccessDate)” 용도
    - .modificationDate → “만료 예정 시각(estimatedExpirationDate)” 용도
- 속성 설정 실패 시 파일 삭제 후 cannotSetCacheFileAttribute 에러

**(6) maybeCached 업데이트**

- 저장 성공 후 maybeCached Set에 파일명 추가(비동기)

---

### **2-4. 조회(value) 흐름 + “캐시 만료 연장” 타이밍**

**(1) maybeCached shortcut 확인 (`false-positive 구조`)**

- maybeCached가 존재하면 “있을 법한 파일인지” 먼저 Set로 빠르게 확인
    - Set에 **없으면** → 바로 nil (빠른 탈락)
    - Set에 **있으면** → 실제 존재는 확정이 아니므로 디스크 확인 필요

**(2) 파일 존재 확인**

- fileExists(atPath:)로 실제 확인

**(3) FileMeta 읽기**

- URLResourceKey로 파일 메타를 조회해 FileMeta 구성
    - lastAccessDate: creationDate
    - estimatedExpirationDate: contentModificationDate
    - fileSize/isDirectory 등도 경우에 따라 사용

**(4) 만료 체크**

- meta.expired(referenceDate)면 nil 반환

**(5) actuallyLoad 분기**

- actuallyLoad == false면 데이터 로드는 생략하고 “존재 여부” 판단만 수행
    - isCached()가 이 경로를 사용(빠름)

**(6) 실제 데이터 로드 + 역직렬화**

- Data(contentsOf: fileURL) → T.fromData(data)
- 실패 시 cannotLoadDataFromDisk 에러

**(7) 만료 연장(Expiration Extending)**

- **데이터를 실제로 읽은 뒤**, 파일 속성 업데이트를 비동기로 수행
    - metaChangingQueue.async { meta.extendExpiration(...) }
- 이유: read 경로 latency를 줄이고, 파일 I/O(속성 변경)를 분리

---

## **3) 정책과 정리**

### **3-1. 만료 연장 정책:`.cacheTime` vs `.expirationTime`**

**`extendExpiration(with:extendingExpiration:)`**

extendExpiration에서 설정하는 속성은 동일:

- .creationDate = “지금(마지막 접근 시각 갱신)”
- .modificationDate = “새 만료 예정 시각”

정책 차이는 **새 만료 예정 시각을 어떻게 계산하느냐**다.

**A) .cacheTime**

- “원래 이 파일이 갖고 있던 TTL(유효기간 길이)을 유지”하면서 갱신
- originalExpiration = lastEstimatedExpiration - lastAccessDate
    
    → 즉, 저장된 “접근 시각”과 “만료 시각”의 차이로 TTL을 복원
    
- 새 만료 = now + originalExpiration
- 효과: **슬라이딩 만료(Sliding Expiration)**
    
    → 자주 읽히는 캐시는 계속 살아남음
    

**B) .expirationTime(let expirationTime)**

- “이번 조회에서 지정한 TTL로 덮어쓰기(override)”
- 새 만료 = now + expirationTime
- 효과: 접근 시점마다 만료 정책을 강제로 재설정 가능

**C) .none**

- 만료 연장 없음 (메타 변경 안 함)

---

### **3-2. 디스크 정리(청소) 흐름**

**A) 만료 파일 제거: removeExpiredValues()**

- 디렉토리 전체 열거(enumerator)
- FileMeta.expired == true 파일 삭제
- 삭제한 URL 목록 반환

**B) 용량 초과 제거: removeSizeExceededValues()**

- sizeLimit == 0이면 제한 없음
- 전체 용량 totalSize() 계산 후 초과하면:
    - 파일 메타를 모아 **lastAccessDate 기준 정렬**
    - 오래 안 쓴 것부터(LRU-ish) 삭제
    - sizeLimit까지 딱 맞추지 않고 **sizeLimit/2까지 줄임**
        - 이유: 다음 정리까지 여유를 만들어 “정리 빈도/비용”을 낮춤

---

## **4) 동시성(DispatchQueue) 설계 포인트**

### **4-1. 동시성(DispatchQueue) 설계 포인트**

- **propertyQueue**: config 접근(get/set)을 직렬화
- **maybeCachedCheckingQueue**: maybeCached Set 접근 보호
- **metaChangingQueue**: 파일 속성 변경 작업 serialize
- @unchecked Sendable: 컴파일러가 완전 증명 못하니, **큐로 스레드 안전을 보장한다**는 선택

---

## **5) 학습하면서 궁금했던 점들 (Questions)**

### **Q1. namespace 사용 (kf + DiskStorage enum type)**

**(1) DiskStorage가 enum인 이유**

- enum 자체가 “값”을 쓰려는 게 아니라 **타입들을 묶는 네임스페이스** 역할
- DiskStorage.Backend, DiskStorage.Config처럼 구조를 한 군데로 모아 “의미/범위”를 명확히 함

**(2) .kf.sha256, .kf.ext는 프로젝트 기본 기능인가?**

- 기본 Swift 기능이 아니라 Kingfisher가 제공하는 “네임스페이스 트릭”이다.
- 목적:
    - 이름 충돌 방지 (sha256 같은 흔한 이름을 전역에 퍼뜨리지 않음)
    - “이 기능은 Kingfisher 관련 기능”이라는 의미 구분
    - 문서화/가독성: kf 아래로 기능을 모아 찾기 쉬움

**(3) KingfisherWrapper / Compatible의 구조**

- kf는 KingfisherWrapper<Base>를 반환하는 진입점
- 기능은 extension KingfisherWrapper where Base == String { var sha256: String } 처럼 wrapper에 붙음
- 값/참조 타입 모두 지원하려고
    - 참조 타입: KingfisherCompatible: AnyObject
    - 값 타입: KingfisherCompatibleValue 를 분리

```swift
protocol KFDCompatibleValue {}
protocol KFDCompatible: AnyObject {}

struct KFDWrapper<Base>: Sendable {
    let base: Base
    init(_ base: Base) {
        self.base = base
    }
}

extension KFDCompatibleValue {
    var kfd: KFDWrapper<Self> {
        get { return KFDWrapper(self) }
        set { }
    }
}

extension KFDCompatible {
    var kfd: KFDWrapper<Self> {
        get { return KFDWrapper(self) }
        set { }
    }
}

extension String: KFDCompatibleValue { }
extension KFDWrapper where Base == String {
    var sha256: String {
        guard let data = base.data(using: .utf8) else { return base }
        let hashed = SHA256.hash(data: data)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// kfd 접근
"KinffisherDemo".kfd.sha256
```
---

### **Q2. 변수명과 의미를 다르게 쓴다**

DiskStorage는 “파일 시스템 메타데이터를 저장소로 활용”하기 위해 원래 의미를 재해석한다.

- modificationDate → **estimatedExpirationDate(만료 예정 시각)로 재해석**
- creationDate → **lastAccessDate(마지막 접근 시각)로 재해석**

이렇게 하면 별도 DB 없이도:

- 만료 체크
- LRU-ish 정리(접근 시각 기반)가 가능해진다.

---

### **Q3. false-positive / shortcut (maybeCached)**

- maybeCached는 “디스크 접근을 줄이기 위한 빠른 필터”다.
- 성질이 false-positive인 이유:
    - Set에 **없다(false)** → 빠른 탈락 힌트 (**절대적 진실이라고 단정하기는 어려움**)
    - Set에 **있다(true)** → 실제 존재는 확정 아님 (“있다”라고 나왔는데 실제론 없음 = false-positive)
        → 따라서 fileExists로 2차 확인 필요

즉 shortcut = “비싼 I/O 전에 싸게 한 번 걸러내는 지름길”.

---

### **Q4. config & _config**

**왜 _config(stored) + config(computed)로 분리하나?**

- 목표: 여러 스레드에서 동기적으로 config를 읽고/써도 **데이터 레이스 없이** 안전하게
- 방법:
    - 실제 저장소는 `private var _config`
    - 외부 노출은 `public var config(computed)`
    - get/set을 propertyQueue.sync로 감싸 접근을 직렬화

```swift
public var config: Config {
  get { propertyQueue.sync { _config } }
  set { propertyQueue.sync { _config = newValue } }
}
```

**왜 config 하나로 못 하냐?**

- computed property 내부에서 self.config를 다시 읽으면 **무한 재귀**로 즉시 크래시
- computed property는 값을 저장할 수 없어서 결국 backing store가 필요

---

### **Q5. Date(TimeInterval) vs file attribute precision + ceil**

```swift
case .cacheTime:
    let originalExpiration: StorageExpiration =
        .seconds(lastEstimatedExpiration.timeIntervalSince(lastAccessDate))
    attributes = [
        .creationDate: Date().fileAttributeDate,
        .modificationDate: originalExpiration.estimatedExpirationSinceNow.fileAttributeDate
    ]
case .expirationTime(let expirationTime):
    attributes = [
        .creationDate: Date().fileAttributeDate,
        .modificationDate: expirationTime.estimatedExpirationSinceNow.fileAttributeDate
    ]
 
/// Date extension
var fileAttributeDate: Date {
    return Date(timeIntervalSince1970: ceil(timeIntervalSince1970))
}
```

### **(올림 ceil) 처리**

- 메모리의 Date는 TimeInterval(Double) 기반이라 소수점 이하(0.1초 등)가 존재할 수 있음
- 파일 속성에 기록될 때는 파일시스템/환경에 따라 정밀도가 낮아 **소수점이 잘리거나 반올림**되어 경계가 흔들릴 수 있음
- 그 결과 “만료가 조금 더 빨리 온 것처럼” 기록되어 테스트가 flaky해질 수 있음

그래서 Kingfisher는 파일 속성에 기록할 Date를 항상 올림 처리:

- “조기 만료” 방향의 흔들림을 줄여 테스트/경계판정을 안정화

---

### **Q6. Sandbox의 Caches 폴더 사용**

→ DiskStory가 갖는 기본 default 폴더는 Library/Caches

```swift
// DiskStorage.Creation.init
init(_ config: Config) {
    let url: URL
    if let directory = config.directory {
        url = directory
    } else {
        url = config.fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }
}
```

- Library/Caches는 **purgeable**(필요하면 OS가 정리/삭제 가능)한 위치
- 캐시 데이터는 “재다운로드/재생성 가능”하다는 전제하에 여기에 두는 게 맞다
- 따라서 DiskStorage는:
    - 폴더가 삭제될 수 있음을 전제로 재생성/재시도 로직을 갖고
    - 캐시 miss를 정상 케이스로 다룬다

---

### **Q7. config.cachePathBlock = nil하는 이유 + 언제 문제가 생기나?**
(+ folder URL vs file URL 정리)**

**1) config.cachePathBlock = nil하는 이유(핵심)**

DiskStorage는 초기화 시점에 Creation(config)에서 **캐시 폴더 경로(directoryURL)** 를 한 번 계산한다.

```swift
let creation = Creation(config)
self.directoryURL = creation.directoryURL
// Break any possible retain cycle set by outside.
config.cachePathBlock = nil
```

- cachePathBlock은 “폴더 경로 계산용 **일회성 클로저**”다.
    
    ```swift
    // DiskStorage.Creation.init
    directoryURL = config.cachePathBlock(url, cacheName)
    ```
    
- directoryURL이 let으로 이미 고정된 이후에는 cachePathBlock을 다시 쓸 일이 없다.
- 그런데 클로저는 외부 객체를 **캡처(strong capture)** 할 수 있어서, 불필요하게 남겨두면 **강한 순환 참조(retain cycle)** 위험이 생긴다.
- 그래서 Kingfisher는 “이미 썼고 앞으로 필요도 없으니” **nil로 지워서 위험을 끊는다.**

---

**2) 언제 문제가 생기나? (기본 구현은 안전함)**

Kingfisher 기본 cachePathBlock은 외부 캡처가 없다.

```swift
// DiskStorage.Config Method
public var cachePathBlock: (@Sendable (_ directory: URL, _ cacheName: String) -> URL)! = {
    (directory, cacheName) in
    return directory.appendingPathComponent(cacheName, isDirectory: true)
}
```

→ 이건 **캡처 0개**라서 retain cycle이 생길 일이 없다.

문제는 **사용자가 cachePathBlock을 커스터마이즈**할 때 생긴다.

(즉, “outside set by outside” 케이스)

---

**3) retain cycle이 생기는 예시**

**`상황`**

- 어떤 CacheManager(class)가 Backend를 프로퍼티로 들고 있음
- cachePathBlock 안에서 CacheManager(self)를 참조(캡처)함

```swift
final class CacheManager {
		var customBaseURL: URL { /* ... */ }
    var backend: DiskStorage.Backend<Data>!

    func makeBackend() {
        var config = DiskStorage.Config(name: "default", sizeLimit: 0)

        // (실수) cachePathBlock이 self를 캡처
        config.cachePathBlock = { _, cacheName in
            return self.customBaseURL.appendingPathComponent(cacheName)
        }

        backend = try! DiskStorage.Backend(config: config)
    }
}
```

**어떤 순환 고리가 생기나?**

- CacheManager → backend (strong)
- backend → _config (strong)
- _config → cachePathBlock (strong)
- cachePathBlock → self(CacheManager) (strong capture)

즉:

**CacheManager → Backend → Config → cachePathBlock → CacheManager**

이 고리가 유지되면 CacheManager를 해제하려 해도 서로 잡고 있어서 메모리에서 안 사라질 수 있다.

---

**4) 왜 cachePathBlock을 Creation이 아니라 Config에 넣었을까?**

- cachePathBlock은 “경로 결정 규칙”이므로 sizeLimit, expiration처럼 **설정(Config)의 일부**로 두는 게 사용성/확장성 측면에서 자연스럽다.
- Creation은 내부 구현 디테일(헬퍼)이고, 사용자가 직접 알 필요가 없다.
- 대신 “외부가 주입한 클로저는 위험할 수 있으니”, **사용 후 nil로 제거**하는 안전장치를 둔다.

---

**5) 헷갈렸던 개념 정리: folder URL vs fileName vs file URL**

**(1) folder URL (=directoryURL)**

- “캐시 파일들이 저장되는 **폴더 경로**”
- 초기화 시점에 Creation이 계산하고 prepareDirectory()가 폴더를 만든다.
- key와 무관하게 “저장소 단위”로 고정된다.

> 예) .../Library/Caches/com.onevcat.Kingfisher.ImageCache.default/
> 

**(2) fileName**

- key로부터 만들어지는 **파일 이름(String)**
- usesHashedFileName이 true면 보통 sha256(key)가 베이스가 된다.
- 필요하면 확장자(.png 등)가 붙는다.

> 예) a3f1c9...e0.png (또는 확장자 없이 해시 문자열만)
> 

**(3) file URL (=fileURL)**

- “폴더 경로 + 파일 이름” = 실제 파일 전체 경로(URL)

공식:

- fileURL = directoryURL.appendingPathComponent(fileName)

> 예) .../Library/Caches/com.onevcat...default/a3f1c9...e0.png
> 

---

### **Q8. 같은 이름 메서드를 여러 개 두는 이유 (value / isCached)**

**1) 왜 오버로드를 쓰나 (핵심 3줄)**

- **Public API는 단순하게**: 대부분 쓰는 형태만 노출 + 기본값 제공
- **내부 구현은 하나로**: 공통 로직을 옵션 많은 내부 메서드로 모아 중복 제거
- **성능 분기 분리**: “Data까지 읽기” vs “존재/만료만 확인”을 깔끔히 분리

---

**2) value method**

```swift
// Public: 사용자가 주로 쓰는 간단 버전
public func value(
    forKey key: String,
    forcedExtension: String? = nil,
    extendingExpiration: ExpirationExtending = .cacheTime
) throws -> T?

// Internal: 실제 구현(옵션이 많고 재사용 목적)
func value(
    forKey key: String,
    referenceDate: Date,
    actuallyLoad: Bool,
    extendingExpiration: ExpirationExtending,
    forcedExtension: String?
) throws -> T?
```

- referenceDate: “이 날짜 기준으로 만료인가?” 체크용
- actuallyLoad: false면 **Data 읽기 생략**(존재/만료만 확인)

---

**3) isCached 오버로드 시그니처**

```swift
// Public: 지금(Date()) 기준으로 캐시돼 있나? (편의)
public func isCached(
    forKey key: String,
    forcedExtension: String? = nil
) -> Bool

// Public: 특정 시점 기준으로 유효한가? (확장)
public func isCached(
    forKey key: String,
    referenceDate: Date,
    forcedExtension: String? = nil
) -> Bool
```

isCached 내부 동작 요약:

- value(... actuallyLoad: false, extendingExpiration: .none) 호출
    → **Data 로드는 안 하고(빠름)**, **만료 연장도 안 함(의도 유지)**

---