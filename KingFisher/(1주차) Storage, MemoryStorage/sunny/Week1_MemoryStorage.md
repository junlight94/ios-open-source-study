## Week1 - 📒 Kinfisher - Cache(1) - MemoryStorage

### 🤔❓ MemoryStorage 타입을 왜 enum 으로 했을까?

```swift
enum MemoryStorage {
  // case 없음
  class Backend { ... }
  struct Config { ... }
  class BackgroundKeepingStorageObject { ... }
  class StorageObject { ... }
}
```
 
 MemoryStorage 은 `Caseless Enum` 패턴을 사용해 MemoryStorage는 실제 일을 하는 애가 아니라<br>관련된 타입(`Backend`, `Config`)을 묶어주는 **폴더** 역할을 함.<br>
 실제 로직은 중첩 타입으로 만들어져있는 Backend, Config에 있음
 
 #### 1️⃣ 인스턴스 생성 방지
  - class/struct로 만들었으면 MemoryStorage() 라는 아무기능 없는 인스턴스 생성이 될수있게 됌.
  - `private init()`을 넣어서 막을 수도 있지만, 코드를 한 줄 더 써야 함
 
 #### 2️⃣ 네임스페이스(Namespace) 역할
  - MemoryStorage도 있고 DiskStorage도 있는데 각각 Backend class와 Config struct를 갖고있음<br> 네임스페이스가 없다면 이름이 길고 복잡해짐 <br>
    - enum으로 묶어서 코드의 소속감이 명확하게하고 깔끔한 네이밍 가능 / 사용할때도 가독성 좋음
    ```swift
    // ex 복잡쓰
    class MemoryStorageBackend { ... }
    struct MemoryStorageConfig { ... }
    class DiskStorageBackend { ... }
    struct DiskStorageConfig { ... }
    ```
    
<br>

---

<br>

### 🤔❓ Backend가 tread-safe라고 주석으로 적혀있는데 어떻게 보장하고있는건지?

```swift
/// > This class is thready safe.
public final class Backend { ... }
```
 
 이미 Thread-safe한 NSCache사용 + non Thread-safe한 Set<String>을 보호하기 위한 NSLock 조합으로 쓰레드 안정성 보장중
 
 #### 1️⃣ key-value로 저장시 타입을 dictionary대신 NSCache 사용
  - Apple 공식 문서에 따르면 `NSCache`는 그 자체로 Thread-safe.
  - `NSCache`는 여러 스레드에서 동시에 `setObject`나 `object(forKey:)`를 호출해도 내부적으로 꼬이지 않도록 설계되어 있음
 
 #### 2️⃣ `keys`변수는 Set타입인데 Thread-safe하지 않은 타입이라 NSLock을 사용
 - NSLock을 이용해 `keys` 변수를 수정하는(store/remove관련) 모든 함수의 시작마다 있는 코드를 확인하면 락/언락 하고있음
   ```swift
   lock.lock()
   defer { lock.unlock() }
   ```
  - lock()으로 `쓰레드`를 잠그고 `defer패턴`을 이용해서 중간에 return을 하든, 에러가 나든 반드시 lock을 풀어주고있음

<br>

---

<br>

### 🤔❓ Key tracking 딜레마
   
```swift
// Breaking the strict tracking could save additional locking behaviors...
// See https://github.com/onevcat/Kingfisher/issues/1233
(해석) 엄격하게 키를 추적하지 않음으로써, 불필요한 락(Lock) 동작을 줄이고 캐시 성능을 높입니다.
```
 `NSCache`는 메모리가 부족하면 내부동작으로 알아서 데이터를 지우게되어있음.
 하지만 `keys(Set)`은 개발자가 관리하고있어서 NSCache타입에서 지워진 키가 여전히 남아있는 데이터 불일치가 발생함.
 완벽한 동기화를 하려면 `NSCache`가 지워질 때 델리게이트(NSCacheDelegate)를 이용해 keys에서도 지워야 하는데
 그런 코드는 없음
 
 왜❓❓
 #### 1️⃣ 데드락 가능성
 - 델리게이트 `cache(_:willEvictObject:)`가 호출되는건 NSCache가 내부동작으로 lock을 걸고 데이터를 지우기 시작할때 데이터를 지우기 직전 호출되는데 이때는 내부동작으로 락되어있는 상태라고 볼수있음.
   <br>델리게이트 메서드 내부에서 keys(Set)를 수정하기위해 우리가 만든 NSLock과 충돌하면 데드락이 발생할 수 있음
   ```
    ex) (1) Thread 1이 store 메서드를 실행하며 lock.lock()으로 쓰레드를 잠금 잡고 NSCache에 접근함.
        (2) 동시에 Thread 2에서 메모리 부족으로 NSCache가 내부 락을 잡고 델리게이트(willEvictObject)를 호출했는데,
            여기서 lock.lock()이 이미 걸렸있어서 서로가 서로의 unlock을 기다리는 데드락 발생
   ```
 
 #### 2️⃣ 성능 저하
- 이미지를 쉴 새 없이 넣고 빼는 라이브러리에서, 삭제될 때마다 매번 델리게이트에서 Set을 수정하는건 오버헤드
 
 #### ✅ 어떻게해결?
 - Kingfisher는 성능을 위해 완벽한 실시간 동기화는 포기하고 나중에 **lazy하게 key값을 제거**해 동기화하는 전략을 사용.
 - `Timer`를 이용해 주기적으로 `removeExpired()`를 호출해서 key값을 동기화중 (default 2분마다)
  ```swift
cleanTimer = .scheduledTimer(withTimeInterval: config.cleanInterval, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    self.removeExpired() // ✅ 타이머로 keys값 동기화
                }
  ```

<br>

---
