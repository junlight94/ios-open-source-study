# DiskStorage (Kingfisher) 정리

DiskStorage는 `T: DataTransformable` 타입을 `Data`로 직렬화한 뒤 디스크 파일로 저장하고, 파일의 속성(`creationDate`, `modificationDate`)을 메타데이터로 활용해서 **만료 정책**과 **용량 제한(LRU 기반 정리)**을 구현하는 디스크 캐시 백엔드다.

---

## 1. DiskStorage가 필요한 이유

Kingfisher는 캐시를 “메모리 + 디스크” 두 계층으로 운영한다.  
메모리 캐시는 빠르지만, 다음 특성 때문에 한계가 있다.

- 앱이 종료되면 사라진다.
- 백그라운드 전환이나 메모리 압박 상황에서 쉽게 비워질 수 있다.
- 즉, **영속성(persistence)**이 없다.

디스크 캐시는 파일로 저장되기 때문에 앱이 종료되어도 남고, 같은 리소스를 다시 다운로드하지 않아도 되므로 네트워크 요청을 줄일 수 있다. 대신 파일 읽기/쓰기 비용(디스크 I/O)과 여러 스레드가 동시에 접근할 때의 동시성 문제가 생긴다.

DiskStorage는 이 “디스크 캐시” 영역을 담당한다.

---

## 2. 전체 구조: DiskStorage.swift를 보는 관점

DiskStorage는 `enum DiskStorage`로 선언되어 있고, 이 `enum`은 타입들을 묶는 네임스페이스 역할을 한다.  
실제 기능 구현은 내부 타입들이 담당한다.

### 2.1 핵심 타입 구성

- `DiskStorage.Backend<T>`
  - 저장/조회/삭제/정리 등 **실제 동작의 본체**
- `DiskStorage.Config`
  - 만료 기간, 용량 제한, 파일명 정책, 저장 경로 등 **정책/규칙 모음**
- `DiskStorage.FileMeta`
  - 파일 속성에서 메타데이터를 읽고, 만료 여부/연장 로직을 담당
- `DiskStorage.Creation`
  - 디스크 캐시 폴더 경로(directoryURL) 생성 책임 분리
- `Error.isFolderMissing`
  - “캐시 폴더가 삭제되어 write가 실패한 경우”를 감지하는 보조 유틸

---

## 3. Backend<T>가 관리하는 상태(프로퍼티) 이해하기

### 3.1 config와 propertyQueue

`Backend`는 여러 메서드에서 `config`를 읽는다. 예를 들면 저장에서는 만료 정책/파일명 규칙을, 정리에서는 용량 제한 등을 사용한다. 이때 여러 스레드에서 동시에 `config`를 읽거나 수정하면 설정값이 중간 상태로 섞여 읽히는 문제가 생길 수 있다.

그래서 `_config` 접근을 `propertyQueue.sync`로 감싸서 읽기/쓰기를 직렬화한다.

- 목적은 **데이터 레이스 방지**
- 동시에 **설정값 일관성 유지**

즉, `config`는 “자주 읽히는 공유 상태”이기 때문에 thread-safe하게 다룬다.

---

### 3.2 directoryURL

`directoryURL`은 이 DiskStorage가 파일을 저장할 “최종 루트 폴더”다.  
키마다 파일이 만들어지므로, 모든 캐시 파일은 이 폴더 아래에 쌓인다.

경로는 `Creation(config)`가 계산한다.

- 기본은 `cachesDirectory / userDomainMask`
- `config.directory`가 있으면 그 경로를 사용
- `cacheName`은 `"com.onevcat.Kingfisher.ImageCache.\(config.name)"`

여기서 중요한 점은 `config.name`이 겹치면 같은 폴더를 공유할 수 있다는 것이다. 정책이 다른 스토리지가 같은 폴더를 공유하면 충돌 위험이 생기므로, `name`은 스토리지 단위로 구분되어야 한다.

---

### 3.3 storageReady

DiskStorage는 초기 디렉터리 생성이 실패한 상태에서 계속 작업을 시도하면 오류가 반복되거나 예상치 못한 상태가 될 수 있다. 그래서 “스토리지가 정상 준비되었는지”를 `storageReady`로 기록한다.

- 디렉터리 생성 실패 → `storageReady = false`
- 이후 저장/조회 시 빠르게 명확한 오류를 반환

즉, `storageReady`는 디스크 캐시의 방어 장치다.

---

### 3.4 maybeCached: Set<String>?

`maybeCached`는 “디스크에 파일이 있는지”를 **1차로 빠르게 추정**하기 위한 참고용 목록이다.  
초기화 시점에 디렉터리 안의 파일 이름 목록을 읽어 `Set`으로 만들어 둔다.

조회할 때는 다음 순서로 사용된다.

1. `maybeCached`에 파일명이 없으면, “없을 가능성이 높다”고 보고 바로 `nil`을 반환한다.
2. `maybeCached`에 파일명이 있으면, 실제로 존재하는지는 다시 `fileExists`로 확인한다.

여기서 핵심은 `maybeCached`는 정확한 데이터가 아니라는 점이다.  
Set에 이름이 있어도 실제 파일이 이미 삭제되었을 수 있다. 이런 상황은 “참고 목록은 통과했지만 실제 파일은 없는 상태”가 된다. 그래서 최종 결론은 반드시 `fileExists`로 확정한다.

`maybeCached`가 실패 없이 동작하려면 “없는데 있다고 판단하는 경우”는 괜찮지만, “있는데 없다고 판단하는 경우”는 위험하다. 그래서 초기화에 실패하면 `maybeCached = nil`로 두고, 이 경우에는 보수적으로 항상 `fileExists`를 수행한다.

#### 왜 Set을 썼나? 배열이면 안 되나?

- 배열에서 `contains`는 평균적으로 O(n)이다.
- Set에서 `contains`는 평균적으로 O(1)에 가깝다.

DiskStorage는 조회가 매우 자주 발생할 수 있기 때문에, “파일명 포함 여부 검사”가 누적되면 비용이 커진다. Set을 쓰면 이 체크를 빠르게 할 수 있다.

---

### 3.5 metaChangingQueue

DiskStorage는 파일을 읽은 뒤, “이 파일이 최근에 사용되었다”는 기록을 남긴다.  
이 기록은 용량 정리(LRU)와 만료 연장 정책을 위해 필요하다.

그런데 이 기록 작업은 디스크 속성 변경(`setAttributes`)을 포함한다. 즉, **추가적인 디스크 I/O**다. 만약 조회 흐름에서 이 작업을 동기로 처리하면, 캐시를 읽을 때마다 “읽기 + 속성 쓰기”가 함께 발생해 응답이 느려질 수 있다.

그래서 DiskStorage는 다음 전략을 선택한다.

- 캐시 조회는 먼저 빠르게 끝낸다.
- 파일 속성 갱신은 `metaChangingQueue`에서 비동기로 처리한다.

이 설계의 목적은 “조회 성능을 지키면서도” LRU/만료 연장에 필요한 기록을 남기는 것이다.

#### 동기였다면 어떤 문제가 생길까?

예를 들어 이미지 리스트 화면에서 스크롤이 빠르게 발생하고, 캐시 조회가 연속으로 일어난다고 하자.

- 동기 처리라면: 조회마다 디스크 읽기 후 속성 쓰기가 붙는다.
- 그러면 캐시 조회 자체가 느려지고, 화면 스크롤이나 렌더링이 끊길 수 있다.
- 특히 같은 파일에 대해 여러 스레드가 동시에 속성 변경을 시도하면 경합도 커진다.

비동기로 보내면 “값 반환”은 빨라지고, 속성 갱신은 큐에서 순서대로 처리된다.

#### 비동기면 LRU가 늦게 갱신돼서 틀릴 수 있지 않나?

가능성은 있다. 다만 이 지연은 보통 몇 ms 수준이고, LRU는 “즉시 반영”이 아니어도 시스템이 망가지지 않는다. LRU 기록은 조회 결과 자체를 바꾸는 데이터가 아니라, 나중에 정리할 때 삭제 순서를 결정하는 참고 정보다.

최악의 경우 “방금 읽은 파일이 정리 대상에 포함되는” 정도의 오차가 생길 수 있지만, 이는 캐시 미스가 한 번 더 발생하는 문제이지 데이터 손상이나 기능 오류로 이어지지 않는다. 그래서 DiskStorage는 속도(핫패스)와 정확성(LRU 기록)의 균형을 비동기로 맞춘다.

---

## 4. 저장(store) 동작

`store(value:forKey:expiration:writeOptions:forcedExtension:)`는 다음 흐름으로 동작한다.

1. `storageReady` 확인  
2. 만료 정책 결정  
   - 파라미터 expiration이 있으면 우선 사용  
   - 없으면 `config.expiration` 사용  
   - 이미 만료된 정책이면 저장을 생략  
3. `T.toData()`로 직렬화  
4. 키로부터 파일 URL 생성  
5. `data.write(to:)`로 디스크에 저장  
6. 파일 속성(attribute) 설정  
7. `maybeCached`에 파일명 추가

### 4.1 파일 속성을 메타데이터로 사용하는 방식

DiskStorage는 별도의 DB나 인덱스 파일을 만들지 않고, 파일 속성만으로 캐시 메타데이터를 관리한다.

- `creationDate` → “마지막 접근 시각(last access)”으로 사용  
- `modificationDate` → “만료 시각(expiration date)”으로 사용  

중요한 포인트는 여기서의 `creationDate`, `modificationDate`가 일반적인 의미(생성일/수정일) 그대로 쓰이지 않는다는 점이다. DiskStorage는 캐시 정책을 위해 이 필드를 “접근 시간/만료 시간”으로 재해석해서 사용한다.

### 4.2 캐시 폴더 삭제 복구

저장 중 `data.write`가 실패했을 때 원인이 “폴더가 삭제됨”이라면 복구가 가능하다. 그래서 `error.isFolderMissing`이면 디렉터리를 다시 만들고 저장을 1회 재시도한다.

캐시 폴더는 OS가 정리하거나 사용자가 앱 데이터를 정리하면서 사라질 수 있기 때문에, 이런 방어 로직이 필요하다.

---

## 5. 조회(value) 동작

DiskStorage는 “파일 존재 확인 + 만료 확인 + 실제 로드”를 하나의 흐름으로 처리한다.  
그리고 `actuallyLoad` 옵션으로 “데이터를 진짜 읽을지”를 선택한다.

### 5.1 조회 흐름

1. `storageReady` 확인  
2. key → fileURL/filePath 계산  
3. `maybeCached`로 1차 필터링  
4. `fileExists`로 실제 존재 확인  
5. `FileMeta` 로드  
6. 만료면 `nil`  
7. `actuallyLoad == false`면 `T.empty` 반환  
8. `Data(contentsOf:)`로 로드 후 `T.fromData` 복원  
9. 조회 후 메타 갱신은 `metaChangingQueue`로 비동기 처리  

### 5.2 만료 연장(extendExpiration)

`FileMeta.extendExpiration`은 조회 후 정책에 따라 “접근 시각과 만료 시각”을 갱신한다.

- `.none`  
  갱신하지 않음
- `.cacheTime`  
  기존 TTL 길이를 유지한 채, 지금을 기준으로 만료 시각을 다시 계산
- `.expirationTime(x)`  
  지정한 만료 정책으로 새 만료 시각 설정

공통적으로 수행되는 갱신은 다음과 같다.

- `creationDate`를 “지금”으로 변경 → 최근 접근 기록
- `modificationDate`를 “새 만료 시각”으로 변경 → 만료 연장

이 방식은 파일 속성만으로 “슬라이딩 만료(sliding expiration)”를 구현하는 사례다.

---

## 6. isCached는 무엇을 확인하나

`isCached`는 “실제 데이터를 읽지 않고” 다음만 확인한다.

- 파일이 존재하는가?
- 만료되지 않았는가?

즉, 캐시 hit 여부만 빠르게 알고 싶을 때 쓰는 API다.  
이를 위해 내부적으로 `actuallyLoad: false`, `extendingExpiration: .none` 같은 옵션을 사용한다.

---

## 7. 삭제(remove / removeAll)

- `remove(forKey:)`
  - 키로 파일 URL을 만든 뒤 `FileManager.removeItem`
- `removeAll()`
  - 캐시 디렉터리 전체를 삭제
  - 필요하면 디렉터리를 다시 생성

디스크 캐시는 “폴더 삭제 후 재생성” 패턴이 자주 쓰인다.

---

## 8. 만료 정리(removeExpiredValues)

만료 정리는 “이미 기한이 지난 파일”을 청소하는 기능이다.

- 디렉터리 전체 열거
- 각 파일의 메타를 읽고 만료 여부 판단
- 만료된 파일 삭제
- 삭제된 URL 목록 반환

메타를 읽는 과정에서 실패하면 그 파일은 “캐시로서 신뢰하기 어렵다”고 보고 만료된 것으로 취급해 제거한다. 이는 정합성과 안전성을 위한 선택이다.

---

## 9. 용량 정리(removeSizeExceededValues): LRU 기반

### 9.1 LRU란?

LRU(Least Recently Used)는 “가장 오래 사용되지 않은 항목부터 제거하는 정책”이다.  
DiskStorage는 용량이 초과되면 최근에 사용된 파일은 남기고, 오래된 파일부터 삭제한다.

### 9.2 동작 흐름

1. `sizeLimit == 0`이면 제한 없음 → 종료  
2. 전체 크기 계산  
3. 초과했으면 파일 목록 + FileMeta 수집  
4. `creationDate`(=last access) 기준 정렬  
5. 오래된 것부터 제거  
6. `sizeLimit / 2`까지 줄임

### 9.3 왜 sizeLimit/2까지 줄이나?

용량을 딱 limit까지 맞추면, 조금만 저장해도 바로 다시 초과하게 된다.  
그 결과 정리 작업이 너무 자주 실행되는 상황(thrashing)이 생긴다.

그래서 한 번 정리할 때 여유 있게 줄여두고, 정리 빈도를 낮춘다.

---

## 10. 파일명 정책(해시/확장자)

DiskStorage는 기본적으로 파일명을 해시로 바꿔 저장한다.

- `usesHashedFileName == true`면 `sha256(key)`
- 목적은 원본 URL 같은 민감 정보가 파일명에 노출되는 것을 줄
