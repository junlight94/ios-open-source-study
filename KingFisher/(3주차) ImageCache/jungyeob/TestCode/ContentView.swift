//
//  ContentView.swift
//  TestCode
//
//  Created by 이중엽 on 2/10/26.
//

import SwiftUI
import Combine

// MARK: - 방식 1: 공유 시리얼 큐 (Kingfisher의 ioQueue 방식)
// 모든 디스크 작업이 하나의 시리얼 큐를 통해 직렬화됨
actor SharedQueueStorage {
    private var disk: [String: String] = [:] // 파일 시스템 시뮬레이션
    // private let ioQueue = DispatchQueue(label: "com.test.sharedQueue") // 하나의 시리얼 큐
    
    func store(key: String, value: String) async {
        // ioQueue.async {
        // 디스크 쓰기 시뮬레이션 (느린 작업)
        // Thread.sleep(forTimeInterval: 0.05)
        try? await Task.sleep(nanoseconds: 500_000_000)
        self.disk[key] = value
        print("✅ [공유큐] 저장 완료: \(key) = \(value)")
        // completion("✅ [공유큐] 저장 완료: \(key) = \(value)")
        // }
    }
    
    func read(key: String) async {
        // ioQueue.async {
        // 디스크 읽기 시뮬레이션
        // Thread.sleep(forTimeInterval: 0.02)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let value = self.disk[key] ?? "nil"
        print("📖 [공유큐] 읽기 완료: \(key) = \(value)")
        // completion("📖 [공유큐] 읽기 완료: \(key) = \(value)")
        // }
    }
    
    func delete(key: String) async {
        // ioQueue.async {
        // 디스크 삭제 시뮬레이션
        // Thread.sleep(forTimeInterval: 0.01)
        try? await Task.sleep(nanoseconds: 100_000_000)
        self.disk.removeValue(forKey: key)
        print("🗑️ [공유큐] 삭제 완료: \(key)")
        // completion("🗑️ [공유큐] 삭제 완료: \(key)")
        // }
    }
}

// MARK: - 방식 2: 각 메서드가 개별적으로 비동기 처리
// 각 메서드가 독립적으로 비동기 처리 → 순서 보장 X
// ⚠️ lock은 Dictionary 크래시 방지용일 뿐, 작업 순서는 여전히 보장 안 됨
class IndividualAsyncStorage {
    private var disk: [String: String] = [:] // 파일 시스템 시뮬레이션
    private let lock = NSLock() // Dictionary 동시 접근 크래시 방지용
    
    func store(key: String, value: String, completion: @escaping (String) -> Void) {
        // 각 메서드가 각자 비동기 처리
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.05)
            self.lock.lock()
            self.disk[key] = value
            self.lock.unlock()
            completion("✅ [개별비동기] 저장 완료: \(key) = \(value)")
        }
    }
    
    func read(key: String, completion: @escaping (String) -> Void) {
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.02)
            self.lock.lock()
            let value = self.disk[key] ?? "nil"
            self.lock.unlock()
            completion("📖 [개별비동기] 읽기 완료: \(key) = \(value)")
        }
    }
    
    func delete(key: String, completion: @escaping (String) -> Void) {
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.01)
            self.lock.lock()
            self.disk.removeValue(forKey: key)
            self.lock.unlock()
            completion("🗑️ [개별비동기] 삭제 완료: \(key)")
        }
    }
}

// MARK: - 방식 3: 각 메서드가 자기만의 시리얼 큐를 가짐
// store/read/delete 각각 전용 시리얼 큐 → 메서드 내부는 직렬이지만 메서드 간 순서 보장 X
class EachMethodOwnQueueStorage {
    private var disk: [String: String] = [:] // 파일 시스템 시뮬레이션
    private let lock = NSLock() // Dictionary 동시 접근 크래시 방지용
    private let storeQueue = DispatchQueue(label: "com.test.storeQueue")   // store 전용 큐
    private let readQueue = DispatchQueue(label: "com.test.readQueue")     // read 전용 큐
    private let deleteQueue = DispatchQueue(label: "com.test.deleteQueue") // delete 전용 큐
    
    func store(key: String, value: String, completion: @escaping (String) -> Void) {
        storeQueue.async {
            // 디스크 쓰기 시뮬레이션 (느린 작업)
            Thread.sleep(forTimeInterval: 0.05)
            self.lock.lock()
            self.disk[key] = value
            self.lock.unlock()
            completion("✅ [개별큐] 저장 완료: \(key) = \(value)")
        }
    }
    
    func read(key: String, completion: @escaping (String) -> Void) {
        readQueue.async {
            // 디스크 읽기 시뮬레이션
            Thread.sleep(forTimeInterval: 0.02)
            self.lock.lock()
            let value = self.disk[key] ?? "nil"
            self.lock.unlock()
            completion("📖 [개별큐] 읽기 완료: \(key) = \(value)")
        }
    }
    
    func delete(key: String, completion: @escaping (String) -> Void) {
        deleteQueue.async {
            // 디스크 삭제 시뮬레이션
            Thread.sleep(forTimeInterval: 0.01)
            self.lock.lock()
            self.disk.removeValue(forKey: key)
            self.lock.unlock()
            completion("🗑️ [개별큐] 삭제 완료: \(key)")
        }
    }
}

// MARK: - ViewModel
@MainActor
class StorageTestViewModel: ObservableObject {
    @Published var sharedQueueLogs: [String] = []
    @Published var individualAsyncLogs: [String] = []
    @Published var eachMethodQueueLogs: [String] = []
    @Published var isRunning = false
    
    private let sharedStorage = SharedQueueStorage()
    private let individualStorage = IndividualAsyncStorage()
    private let eachMethodQueueStorage = EachMethodOwnQueueStorage()
    
    /// 테스트: 저장 → 읽기 → 삭제를 "거의 동시에" 호출
    func runTest() {
        sharedQueueLogs = []
        individualAsyncLogs = []
        eachMethodQueueLogs = []
        isRunning = true
        
        // =====================================================
        // 방식 1: 공유 시리얼 큐 (Kingfisher 방식)
        // store → read → delete 순서로 호출하면, 큐에 순서대로 쌓임
        // 결과: 항상 저장 → 읽기(값 있음) → 삭제 순서 보장
        // =====================================================
        // sharedStorage.store(key: "image1", value: "cat.png") { [weak self] log in
        
        Task {
            await sharedStorage.store(key: "image1", value: "cat.png")
            await sharedStorage.read(key: "image1")
            await sharedStorage.delete(key: "image1")
        }
        
        // =====================================================
        // 방식 2: 개별 비동기 처리
        // store, read, delete가 각각 global() 큐에서 동시에 실행됨
        // 결과: 순서가 뒤죽박죽 → 저장 전에 읽기/삭제가 먼저 될 수 있음
        // =====================================================
        individualStorage.store(key: "image1", value: "cat.png") { [weak self] log in
            DispatchQueue.main.async { self?.individualAsyncLogs.append(log) }
        }
        individualStorage.read(key: "image1") { [weak self] log in
            DispatchQueue.main.async { self?.individualAsyncLogs.append(log) }
        }
        individualStorage.delete(key: "image1") { [weak self] log in
            DispatchQueue.main.async { self?.individualAsyncLogs.append(log) }
        }
        
        // =====================================================
        // 방식 3: 각 메서드가 자기만의 시리얼 큐
        // store는 storeQueue, read는 readQueue, delete는 deleteQueue
        // 각 큐는 독립이라 서로 간의 순서 보장 X
        // =====================================================
        eachMethodQueueStorage.store(key: "image1", value: "cat.png") { [weak self] log in
            DispatchQueue.main.async { self?.eachMethodQueueLogs.append(log) }
        }
        eachMethodQueueStorage.read(key: "image1") { [weak self] log in
            DispatchQueue.main.async { self?.eachMethodQueueLogs.append(log) }
        }
        eachMethodQueueStorage.delete(key: "image1") { [weak self] log in
            DispatchQueue.main.async { self?.eachMethodQueueLogs.append(log) }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.isRunning = false
        }
    }
    
    /// 테스트 2: 같은 키에 여러번 쓰기 + 읽기 (동시성 문제 심화)
    func runStressTest() {
        sharedQueueLogs = []
        individualAsyncLogs = []
        eachMethodQueueLogs = []
        isRunning = true
        
        // 공유 시리얼 큐: 순서대로 직렬 처리 → 항상 마지막 값이 "v5"
        Task {
            for i in 1...5 {
                await sharedStorage.store(key: "data", value: "v\(i)")
            }
            await sharedStorage.read(key: "data")
        }
        
        // 개별 비동기: 5개의 쓰기가 동시에 경쟁 → 최종 값이 무엇인지 예측 불가
        for i in 1...5 {
            individualStorage.store(key: "data", value: "v\(i)") { [weak self] log in
                DispatchQueue.main.async { self?.individualAsyncLogs.append(log) }
            }
        }
        individualStorage.read(key: "data") { [weak self] log in
            DispatchQueue.main.async { self?.individualAsyncLogs.append(log) }
        }
        
        // 각 메서드 개별 큐: store들은 storeQueue에서 직렬이지만, read는 readQueue라 별개
        for i in 1...5 {
            eachMethodQueueStorage.store(key: "data", value: "v\(i)") { [weak self] log in
                DispatchQueue.main.async { self?.eachMethodQueueLogs.append(log) }
            }
        }
        eachMethodQueueStorage.read(key: "data") { [weak self] log in
            DispatchQueue.main.async { self?.eachMethodQueueLogs.append(log) }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.isRunning = false
        }
    }
}

// MARK: - View
struct ContentView: View {
    @StateObject private var vm = StorageTestViewModel()
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                
                Text("ioQueue 직렬 큐 vs 개별 비동기 처리")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                
                // 버튼
                HStack {
                    Button("기본 테스트") {
                        vm.runTest()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.isRunning)
                    
                    Button("스트레스 테스트") {
                        vm.runStressTest()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(vm.isRunning)
                }
                .frame(maxWidth: .infinity)
                
                // 공유 큐 결과
                VStack(alignment: .leading, spacing: 6) {
                    Text("🔵 공유 시리얼 큐 (Kingfisher 방식)")
                        .font(.subheadline).bold()
                    Text("호출 순서: store → read → delete")
                        .font(.caption).foregroundColor(.gray)
                    
                    if vm.sharedQueueLogs.isEmpty {
                        Text("테스트를 실행해주세요")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(Array(vm.sharedQueueLogs.enumerated()), id: \.offset) { idx, log in
                            Text("\(idx + 1). \(log)")
                                .font(.caption)
                        }
                    }
                }
                .padding()
                .background(Color.blue.opacity(0.05))
                .cornerRadius(12)
                
                // 개별 비동기 결과
                VStack(alignment: .leading, spacing: 6) {
                    Text("🔴 개별 비동기 처리 (global 큐)")
                        .font(.subheadline).bold()
                    Text("호출 순서: store → read → delete")
                        .font(.caption).foregroundColor(.gray)
                    
                    if vm.individualAsyncLogs.isEmpty {
                        Text("테스트를 실행해주세요")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(Array(vm.individualAsyncLogs.enumerated()), id: \.offset) { idx, log in
                            Text("\(idx + 1). \(log)")
                                .font(.caption)
                        }
                    }
                }
                .padding()
                .background(Color.red.opacity(0.05))
                .cornerRadius(12)
                
                // 각 메서드 개별 큐 결과
                VStack(alignment: .leading, spacing: 6) {
                    Text("🟢 각 메서드가 자기만의 시리얼 큐")
                        .font(.subheadline).bold()
                    Text("호출 순서: store → read → delete (각각 다른 큐)")
                        .font(.caption).foregroundColor(.gray)
                    
                    if vm.eachMethodQueueLogs.isEmpty {
                        Text("테스트를 실행해주세요")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(Array(vm.eachMethodQueueLogs.enumerated()), id: \.offset) { idx, log in
                            Text("\(idx + 1). \(log)")
                                .font(.caption)
                        }
                    }
                }
                .padding()
                .background(Color.green.opacity(0.05))
                .cornerRadius(12)
                
                // 설명
                VStack(alignment: .leading, spacing: 8) {
                    Text("💡 핵심 차이점")
                        .font(.subheadline).bold()
                    
                    Text("""
                    🔵 공유 시리얼 큐 (ioQueue):
                    • 모든 작업이 하나의 큐에 순서대로 들어감
                    • store → read → delete 순서가 "보장"됨
                    • read 시점에 store가 완료되어 값이 존재
                    
                    🔴 개별 비동기 처리 (global 큐):
                    • 각 메서드가 global() concurrent 큐에서 동시 실행
                    • store(0.05초)보다 delete(0.01초)가 먼저 끝남
                    • read 시 값이 없거나, 삭제 후 저장되는 등 순서 꼬임
                    
                    🟢 각 메서드가 자기만의 시리얼 큐:
                    • store는 storeQueue, read는 readQueue, delete는 deleteQueue
                    • 각 큐가 독립 → 메서드 간 순서 보장 X
                    • 🔴와 비슷하게 꼬이지만, 같은 종류 작업끼리는 직렬 보장
                    • 예: store 5번 호출 시 v1→v2→v3→v4→v5 순서 보장
                    """)
                    .font(.caption)
                }
                .padding()
                .background(Color.yellow.opacity(0.1))
                .cornerRadius(12)
            }
            .padding()
        }
    }
}

#Preview {
    ContentView()
}
