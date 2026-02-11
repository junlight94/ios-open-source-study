## Week2 - 📒 Kinfisher - Cache(2) - DiskStorage

### 🤔 config 값 관리는 왜 이렇게 하는지?

```swift
// 동기화 큐 생성
private let propertyQueue = DispatchQueue(...) // 동기화 큐 생성

// 실제 데이터 숨김
private var _config: Config                   

// 읽기/쓰기 동기화
public var config: Config {    
		get { propertyQueue.sync { _config } }              
		set { propertyQueue.sync { _config = newValue } }   
}
```
config라는 실제 데이터는 `private`으로 숨겨놓고, 접근 가능한 `public` 프로퍼를을 따로 만들어서 `get/set`에 따라 숨겨놓은 config 데이터에 접근하는 방식을 사용중.
이 때 만들어둔 하나의 Queue.sync 이용한.. 방식!


### 1️⃣  thread-safe를 보장하기위해 SerialQueue + sync 사용

킹피셔 사용은 대부분이 멀티스레드 환경에서 이뤄지다보니 thread-safe가 필수라고 보면 됌

```swift
// ex
imageView1.kf.setImage(with: url1)  // 백그라운드 스레드 1
imageView2.kf.setImage(with: url2)  // 백그라운드 스레드 2
ImageCache.default.diskStorage.config.expiration = .days(14)
imageView3.kf.setImage(with: url3)  // 백그라운드 스레드 3

// 모두 같은 ImageCache.default 사용
// -> 같은 DiskStorage.Backend 사용
// -> 같은 config 접근
// 중간에 동적 설정 변경이있음 (다른 스레드에서는 이미지 저장 중인 상태임)
// config 값에 접근하면서 값을 변경해야함 
// -> 충돌 방지 필요! = Thread-Safe 필수
```

- serialQueue사용이유
    - config 읽기/쓰기가 서로 다른 쓰레드에서 동시에 발생하는 상황에선
        - (1)잘못된 데이터에 접근하게될 가능성이 있음 (바뀌기전 킹피셔를 호출했지만 config접근 타이밍에 값이 바뀌어버린 경우 잘못된 데이터 읽게 됌)
        - (2) 더 나쁘면 race condition으로 크래시 발생할수 있음
    
     ⇒ ✅ 직렬 Queue + sync 를 통한 읽기/쓰기로 이를 해결함
    
- async가 아닌 sync 를 사용한이유
    - `config` Getter는 반드시 `Config` 객체를 즉시 반환해야 함. 만약 async를 썼다면 우선 Void를 반환하고 다음 코드라인으로 넘어가 버리면서 문제가 될수있기에 뭐 ..당연히 sync..

#### ⁉️ MemoryStorage`의 Config는 왜 다르게 public 하나로만 관리하는지?
- `MemoryStorage` 의 Config를 보면 config가 변경됐을 때(쓰기), NSCache의 설정값을 바꾸는 작업만 존재함. 근데  NSCache 뭐다? 원래가 thread-safe한 타입이다~
내부적으로 알아서 쓰레드안정성을 보장해주니까 이렇게 개발자가 관리해줄 필요없다~

#### ⁉️ 결국 멀티 스레드에서 작업해도 config 사용시 sync에서 대기하는 상황이 되는거아닌가? 그럼 멀티 스레드의 효과가 줄어드는거 아니니?????
- 맞음ㅎㅎ 결과적으론 안전하지만 병목(Bottleneck) 발생으로 멀티스레드의 이점이 줄어듦.
하지만!  Config ****접근은 나노초 단위로 매우 짧고, 실제론 `Data(contentsOf: fileURL)` , `data.write(to: fileURL)`  같은 데이터 다운로드/쓰기가 오래 걸리는 작업이기때문에 Config 동기화는 전체 시간의 0.0002%로 실질적 성능에 영향이 거의없음. 
더 나은 코드도 보여줬는데 (읽기는 async, 쓰기만 sync로 접근하는 코드였음)

#### ⁉️ Config 타입을 Actor나 Class(참조타입)으로 관리하는건 어떨지?

- Class로 하면, 외부에서 이 객체를 참조로 들고 있다가 내부 값을 바꿀 수 있게 됨.. Backend가 모르는 사이에 내부 상태가 변하는 side-effect 발생 가능성있음 (지금처럼 struct를 사용해야 복사로 전달되니까 사용하는 쪽에서 값을 수정해도 실제 저장소의 설정에는 영향이 없음, 오직 `set`을 통해서만 설정을 변경할 수 있는 상황)

- Actor의 제약: 하위호환성 문제가있고, Actor로 만들면, Config안의 모든 프로퍼티 접근 `sizeLimit`, `expiration`이 `await`를 필요로 하는 비동기 작업이 되므로 따로 처리해야하는 번거로움이 있음..

---

### 🤔 maybeCached, maybeCachedCheckingQueue역할/ false-positive란?

- `maybeCached: Set<String>?`
    - 디스크에 저장하는 파일명을 Set으로도 저장 중
    - false-positive (라고 주석에있음..밑에서 자세히)
    - Set타입이라 접근속도 O(1)
    - `maybeCached` 에 저장되는 값은 insert만 되고 remove는 되지않고있음.
- `maybeCachedCheckingQueue`
    - `maybeCached` 에 접근을 thread-safe하게 보장해주는 큐

### 1️⃣ false-positive ??

```swift
func value(...) throws -> T?
        {
            ...
            // ✅ fileManager.fileExists가 오래 걸리기 때문에 
            // maybeCached 메모리로 우선 체크하는것 => 검색 성능 향상!
            let fileMaybeCached = maybeCachedCheckingQueue.sync {
                return maybeCached?.contains(fileURL.lastPathComponent) ?? true
            }
            guard fileMaybeCached else {
                return nil
            }
            guard fileManager.fileExists(atPath: filePath) else {
                return nil
            }
            ...
        }
```

- 있다고(positive) 했는데 실제로는 없음(false)을 뜻함
    - 위 코드를 보면 `maybeCached` 에서 true로 값이 있다고 해도 실제 디스크에는 없는 경우가 있음 (ex. finder에서 삭제되서 `maybeCached` 는 모르는상태 등)
    - 굳이 이렇게 하는건 디스크에서 있는지 없는지 확인하는것보다 O(1)이라는 빠른 속도로 먼저 확인할수 있어서 미리 가드문으로 return 처리할 수 있어서임. 속도와 성능 최적화를 위해 이렇게 처리했다고할 수 있음. 즉, 메모리를 이용해서 '정답지 후보'를 만드는 것과 같음.
- …
    - **True Positive (진짜 있음):** `Set`에 있고, 실제 디스크에도 있음. (정상)
    - **True Negative (진짜 없음):** `Set`에 없고, 실제 디스크에도 없음. (정상)
    - **False Positive (거짓 있음):** `Set`에는 있는데, 실제 디스크엔 없음. (약간의 성능 손실)
    - **False Negative (거짓 없음):** `Set`에는 없는데, 실제 디스크엔 있음. (치명적, 데이터가 있는데도 네트워크에서 다시 다운로드함)
    
    Kingfisher는 False Positive는 허용하되, False Negative는 절대 허용하지 않는다는 전략을 사용
    

#### ⁉️ `maybeCached` 는 디스크에 없는걸 확인하고도 왜 remove하지 않는가?

- (1) 동기화 비용이 배보다 배꼽이 더 크기 때문임. 디스크에서 파일이 삭제되는 시점은 매우 다양하고 복잡해서 그 모든 순간에 삭제 로직을 넣고 `Queue` 를 이용해 작업하려면 "빠른 체크를 위해 만든 Set" ****의 의미가 사라짐
- (2) 앱을 껐다 켜면 다시 완벽해지기 때문에, 굳이 실행 중에 복잡한 동기화 로직을 넣어 코드를 지저분하게 만들 필요가 없음
- 즉. 실용적인 최적화(Pragmatic Optimization)를 추구한 킹피셔라고 할 수 있음. 완벽한 일관성대신 적절한 수준의 정확도와 최고의 성능을 맞바꾼 전략임.

#### ⁉️ 이런 전략은 언제 사용하면 좋은가? / 주의할점은?

- 1️⃣ 비용의 비대칭성이 존재할 때
    - 데이터가 있는지 확인하는 작업(디스크/네트워크)은 비싼데, 데이터가 없다고 결론 내리는 작업(메모리)은 매우 쌀 때.
    - 실제로 없는 데이터에 대해 비싼 디스크 I/O를 발생시키지 않고 메모리에서 즉시 `nil`을 반환하여 전체 시스템의 처리량을 높일 수 있음
- 2️⃣ 없음(Negative)에 대한 응답이 빈번할 때
    - 앱 로직상 존재하지 않는 리소스를 요청하는 경우가 많거나, 중복 요청이 많은 경우.
    - `maybeCached` 같은 필터가 없다면, 없는 데이터를 찾으려고 매번 디스크 폴더를 뒤져야 하는데. 필터가 있으면 99%의 "없음" 요청을 메모리 단에서 컷트할 수 있음.
- 3️⃣ 데이터의 삭제가 빈번하지 않거나, 삭제 동기화 비용이 클 때
    - Kingfisher처럼 만료된 파일을 지우는 작업이 백그라운드에서 한꺼번에 일어나거나, 외부 요인으로 데이터가 사라질 수 있을 때.
    - 디스크에서 파일이 하나 사라질 때마다 메모리의 `Set`을 실시간으로 업데이트하려면 복잡한 동기화 로직이 필요한데 차라리 "지우는 건 나중에 앱 껐다 켤 때 동기화하고, 지금은 좀 틀려도 안전하게 가자"는 판단이 효율적일 수 있음

주의할 점 (Trade-off)

1️⃣ 비용의 비대칭성이 존재할 때

- 메모리 과부하 조심. `maybeCached`에 수만 개의 파일명을 넣으면 메모리가 부족해질 수 있습니다. (Kingfisher도 파일명 String을 그대로 저장하므로 파일이 너무 많으면 메모리 부하가 생긴다고함)
- 수명 관리. 앱이 종료되지 않고 며칠 동안 켜져 있다면, 디스크와 메모리 사이의 괴리가 점점 커져서 결국 필터로서의 기능을 상실(모든 요청에 대해 일단 디스크를 확인하게 됨)할 수 있음

---
