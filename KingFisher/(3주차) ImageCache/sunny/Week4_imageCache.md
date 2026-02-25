## Week4 - 📒 Kinfisher - Cache(4) - ImageCache

### 전체 구조

`ImageCache`는 **두 개의 저장소**를 조합한 하이브리드 캐시.

```bash
ImageCache
├── MemoryStorage (RAM에 저장, 빠름)
└── DiskStorage   (파일로 저장, 느리지만 앱 재시작 후에도 유지)
```

이미지를 가져올 때도 **Memory → Disk → 네트워크** 순으로 확인

---

### 🤔 computedKey 관리

```bash
extension String {
    func computedKey(with identifier: String) -> String {
        if identifier.isEmpty {
            return self
        } else {
            return appending("@\(identifier)")
        }
    }
}
```

왜 이게 필요할까?

같은 URL로 받은 이미지라도 다른 processor(예: 흑백 필터, resize)를 적용하면 **다른 결과물**이 나옴
→ 그래서 캐시 키도 달라야함

```bash
"https://example.com/cat.png"                    → 원본
"https://example.com/cat.png@grayscale.processor" → 흑백 처리된 버전
"https://example.com/cat.png@resize_100x100"      → 리사이즈 버전
```

같은 이미지지만 다른 캐시사용을 단순한 문자열 조합으로 설계함.

---

### **🤔** Initializer 가 4개나 있는 이유 (= initializer 계층구조)

```bash
// ① 
public init(memoryStorage:diskStorage:)

// ②
public convenience init(name: String)

// ③
public convenience init(name: String, cacheDirectoryURL: URL?, diskCachePathClosure: ...) throws

// ④ (internal - 외부에서 못 씀)
convenience init(noThrowName:cacheDirectoryURL:diskCachePathClosure:)
```

convenience init은 같은 클래스의 다른 init을 호출해야 하니까 사실 이 4개 이니셜라이저는 하나의 체인으로 볼 수 있음.
 

```bash
// 1
②  init(name:)
        ↓ 호출
④  init(noThrowName:...)
        ↓ 호출
①  init(memoryStorage:diskStorage:)  ← 실제 초기화는 여기서만 일어남

// 2
③  init(name:cacheDirectoryURL:...) throws
        ↓ 호출
①  init(memoryStorage:diskStorage:)
```

```bash
// ① 
public init(memoryStorage:diskStorage:)

let mem = MemoryStorage.Backend<KFCrossPlatformImage>(config: myMemConfig)
let disk = try DiskStorage.Backend<Data>(config: myDiskConfig)
let cache = ImageCache(memoryStorage: mem, diskStorage: disk)
```

- 진짜 이니실려라이저.
    - 실제로 프로퍼티에 값을 넣는 지정 이니셜라이저. 나머지 셋은 이걸 편하게 쓰기 위한 편의이니셜라이저
    - 언제 쓰나? 스토리지를 완전히 커스텀하고 싶을 때
    - 직접 메모리/디스크 설정을 만들어서 넘기는 고급 사용법

```bash
// ②
public convenience init(name: String)

let cache = ImageCache(name: "thumbnails")
```

- 일반 유저용
    - 언제쓰나? 가장 단순하게 생성할 때. 이름만 주면 나머지는 알아서 생성
    - throw가 없는 이유 아래에서 설명

```bash
// ③
public convenience init(name: String, cacheDirectory
                                              URL: URL?, diskCachePathClosure: ...) throws

// ex. 공유 컨테이너에 저장 (App Extension과 공유)
let sharedURL = FileManager.default
                                        .containerURL(forSecurityApplicationGroupIdentifier: "group.com.myapp")

let cache = try ImageCache(name: "shared", cacheDirectoryURL: sharedURL)
```

- 커스텀 경로용
    - 언제쓰나? 캐시를 저장할 디렉토리를 직접 지정하고 싶을 때
    - 디렉토리가 없거나 권한이 없으면 **진짜로 실패**할 수 있기 때문에 `throws`가 붙음

```bash
// ④
convenience init(noThrowName: cacheDirectoryURL: diskCachePathClosure:) {
    // throw 버전 대신 이걸 씀
    let diskStorage = DiskStorage.Backend<Data>(noThrowConfig: config, creatingDirectory: true)
    self.init(memoryStorage: memoryStorage, diskStorage: diskStorage)
}
```

- 내부 전용 브릿지 역할
    - 언제쓰나? ②번(`init(name:)`)이 `throws` 없이 동작하게 해주는 내부 우회로
- 먼저 배포된 ②번 이니셜라이저의 하위호환성을 위해 있음.. 예전부터 throw가 없던 ②번 이니셜라이저를 제공했는데, 너중에 throw를 추가하면 기존 코드가 다 망가지게되니까 내부적으로 `noThrow` 버전을 쓰는 우회로(④)를 만든 것.

**⁉️ throw vs no-throw 왜 나뉘나?**

③번 이니셜라이저 내부에서 디스크 Storage를 만들 때 실제로 폴더를 생성하는데 이 때  실패할 수 있음 ( = throw가 발생할 수 있음) 

```bash
// ③번 내부
let diskStorage = try DiskStorage.Backend<Data>(config: config)
//                ^^^^ 여기서 실패 가능
```

- 실패 상황 예시
    - 경로가 잘못됨
    - 해당 위치에 쓰기 권한 없음
    - 디스크 공간 부족
    - 이미 파일이 그 경로에 존재

**⁉️ 그럼  ④은 어떻게 throw없이 디스크 스토리지를 만들고 있는가?**

- 디스크 스토리지에도 두 가지 이니셜라이저가있고, noThrow하는 버전으로 사용 중.
    - `init(config:)` → `throws` (실패하면 에러 던짐)
    - `init(noThrowConfig:creatingDirectory:)` → throw 없음 (실패해도 일단 진행, 나중에 쓸 때 실패)
- 갑자기 throw를 추가하게된다면..?
    
    ![스크린샷 2026-02-23 오후 1.54.20.png](attachment:8d3f5836-66dc-4f5f-b17d-63443de35655:스크린샷_2026-02-23_오후_1.54.20.png)
    

**⁉️ 한 눈에 정리**

사용자가 선택 기중

- 이름만 줄게                 → ② init(name:)                                            // throw 없음
- 경로도 지정할게           → ③ init(name:cacheDirectoryURL:)        // throws, try 필요
- 스토리지 직접 만들게   → ① init(memoryStorage:diskStorage:)   // throw 없음

throw 유무 기준:

- throws    = 디렉토리 생성을 엄격하게, 실패하면 알려줌
- no throw  = 디렉토리 생성 실패해도 일단 진행, 나중에 쓸 때 실패

---

### 💾 store 메서드 - 비동기 흐름 이해하기

```bash
open func store(_ image: KFCrossPlatformImage, ...) {
    // 1. 메모리 저장 - 동기, 즉시 완료
    memoryStorage.storeNoThrow(value: image, forKey: computedKey, ...)

    guard toDisk else { /* 완료 콜백 바로 호출 */ return }

    // 2. 디스크 저장 - ioQueue에서 비동기
    ioQueue.async {
        let data = serializer.data(with: image, original: original)
        self.syncStoreToDisk(data, ...)
    }
}
```

```bash
[호출 스레드]
     │
     ├─ memoryStorage.store() ← 동기
     │
     └─ ioQueue.async {       ← 비동기
            serialize image to Data
            write to disk
            call completionHandler on callbackQueue
        }
```

메모리 저장은 동기(`storeNoThrow`), 디스크 저장은 IO Queue에서 비동기. 
→ 왜 이렇게 나눴을까? 디스크 I/O는 느리니까 메인 스레드를 블락하면 안 되기 때문

---

### 🔍 retrieveImage - 캐시 조회

```bash
open func retrieveImage(forKey key: String, options: KingfisherParsedOptionsInfo, ...) {
    // 1단계: 메모리 확인
    if let image = retrieveImageInMemoryCache(forKey: key, options: options) {
        callbackQueue.execute { completionHandler(.success(.memory(image))) }
        return
    }
    
    // 옵션: 메모리에 없으면 그냥 nil 반환 (네트워크 재요청용)
    if options.fromMemoryCacheOrRefresh {
        callbackQueue.execute { completionHandler(.success(.none)) }
        return
    }

    // 2단계: 디스크 확인
    self.retrieveImageInDiskCache(forKey: key, ...) { result in
        // 디스크에서 찾으면 → 메모리에도 올려두기 (다음 요청은 빠르게!)
        self.store(image, forKey: key, options: cacheOptions, toDisk: false) { _ in
            callbackQueue.execute { completionHandler(.success(.disk(image))) }
        }
    }
}
```

메모리 확인 → 옵션에서 fromMemoryCacheOrRefresh면 return → 디스크 확인
만약 **디스크에서 찾았다면 메모리에도 저장 (**= 전형적캐시 워밍(Cache Warming) 패턴)

**⁉️ 캐시워밍 패턴**

말 그대로 미리 데워놓는것 = 자주 쓰는 물건을 서랍(디스크) 대신 책상 위(메모리)에 올려두는 것.

```bash
첫 번째 요청:
메모리 확인 → ❌ 없음
디스크 확인 → ✅ 있음! → 메모리에도 저장해둠

두 번째 요청:
메모리 확인 → ✅ 있음! → 바로 반환 (디스크까지 안 감)
```

---

### **🤔** retrieveImage 메서드의 접근제한자는 왜 open으로 한 후 주석으로 override를 하지말라고했을까? 애초에 Public으로 두면됐잖아?

```bash
    /// > This method is marked as `open` for compatibility purposes only. Do not override this method. Instead,
    /// override the version ``ImageCache/retrieveImageInDiskCache(forKey:options:callbackQueue:completionHandler:)``
    /// accepts a ``KingfisherParsedOptionsInfo`` value.
    
    open func retrieveImage(
        forKey key: String,
        options: KingfisherOptionsInfo? = nil,
        callbackQueue: CallbackQueue = .mainCurrentOrAsync,
        completionHandler: (@Sendable (Result<ImageCacheResult, KingfisherError>) -> Void)?
    )
```

접근제한자 open / public

- open = 외부에서 사용 및, 상속 후 override 가능
- public = 외부에서 사용 가능, override 불가능

```bash
// ImageCache에 같은 이름의 메서드가 두 개 있음

// 1. KingfisherParsedOptionsInfo 받음

open func retrieveImage(
    forKey key: String,
    options: KingfisherParsedOptionsInfo  // ← 파싱된 버전
) { ... }

// 2. 편의 KingfisherOptionsInfo 받음 (내부에서 버전 1을 호출하는 단순 래퍼)

open func retrieveImage(
    forKey key: String,
    options: KingfisherOptionsInfo? = nil  // ← 원본 버전
) {
    retrieveImage(...)
}
```

- 2번 retrieveImage 메서드는 내부에서 1번 메서드를 호출중인데 override하면 내부 호출부분이 빠져서 실제 적용이 안될 수도 있음.
- 그럼 왜 2를 open으로 열어뒀냐?
    - 옛날 버전 킹피셔엔 KingfisherParsedOptionsInfo 가 없었기에 2번 메서드만 있었고, open으로 공개해서 많은 사람들이 B를 오버라이드해서 씀.
    - 새 버전 킹피셔에 KingfisherParsedOptionsInfo를 추가하면서 버전 1이 핵심이 됨… → 그런데 2의 open을 닫아버리면..? 기존 서브클래스 코드 전부 컴파일에서가남..

---

## 🤔 토론해볼 만한 주제

1. clearDiskCache 메서드에서 do-catch에서 에러가 나도 핸들러를 호출하고,
cleanExpiredDiskCache 메서드 에서는 성공했을때만 핸들러를 부르고있음.. 왜그럴까?

```bash
cache.clearDiskCache {
    print("정리 완료!")  // 실패한걸수도있음 ...
}

cache.cleanExpiredCache {
     // 종료후 작업 // 영원히 안불릴 수 있음
}
```

1. TempProcessor를 밖에 만들어두면 될것같은데.. 왜 메서드안에서 계속 만드는걸까

```bash
open func store(_ image: ..., processorIdentifier identifier: String = "") {
    
    struct TempProcessor: ImageProcessor {  // ← store 호출할 때마다 타입 정의
        let identifier: String
        func process(...) -> KFCrossPlatformImage? {
            return nil  // 아무것도 안 함
        }
    }
```
