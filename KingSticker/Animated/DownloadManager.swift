//
//  DownloadManager.swift
//  KingSticker
//
//  Copyright © 2020 Purkylin King
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.

import Foundation

private let queue = DispatchQueue(label: "download", qos: .background)
private let syncQueue = DispatchQueue(label: "sync", qos: .utility)

/// Download manager
public class DownloadManager {
    static let shared = DownloadManager()
    
    /// default max cache time is one week
    public var maxCachedTime: TimeInterval = 3600 * 24 * 7
    
    private let maxConcurrentTasks = 6
    private let semaphore: DispatchSemaphore
    
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        return session
    }()
    
    private var taskDict: [URL : DownloadTask] = [:]
    
    private init() {
        semaphore = DispatchSemaphore(value: maxConcurrentTasks)
        setupNotification()
    }
    
    func setupNotification() {
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            slog("Enter background and suspend all tasks")
            self?.suspendAll()
        }
        
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            slog("Enter foreground and resume all tasks")
            self?.resumeAll()
        }
    }
    
    private func suspendAll() {
        syncQueue.sync {
            for task in taskDict.values {
                task.suspend()
            }
        }
    }
    
    private func resumeAll() {
        syncQueue.sync {
            for task in taskDict.values {
                task.resume()
            }
        }
    }
    
    /// Download file
    func download(url: URL, to position: URL, completion: @escaping (Data?) -> Void) {
        func createTask() -> DownloadTask {
            slog("schedule a task")
            let task = self.session.dataTask(with: url) { [weak self] (data, response, error) in
                var result: Data? = nil
                if let response = response as? HTTPURLResponse, response.statusCode == 200, let data = data, data.count > 0 {
                    slog("success a download task")
                    try? data.write(to: position)
                    result = data
         
                } else {
                    slog("fail a download task")
                }
                
                syncQueue.sync {
                    if let destination = self?.taskDict[url] {
                        destination.notify(data: result)
                        self?.taskDict.removeValue(forKey: url)
                    }
                    
                    self?.semaphore.signal()
                }
            }
            
            return DownloadTask(url: url, task: task, completion: completion)
        }
        
        func run() {
            // Check again whether downloaded
            if let data = ResourceManager.shared.cacheData(for: url) {
                completion(data)
                return
            }
            
            semaphore.wait()
            
            if let task = taskDict[url] {
                // Already exists
                task.add(callback: completion)
            } else {
                let newTask = createTask()
                syncQueue.sync {
                    taskDict[url] = newTask
                }
                newTask.resume()
            }
        }
        
        queue.async {
            run()
        }
    }
    
    /// Cancel all tasks
    func cancelAllTasks() {
        slog("cancel all downloading tasks")
        syncQueue.sync {
            taskDict.forEach { (_, task) in
                task.cancel()
            }
            
            taskDict.removeAll()
        }
    }
    
    /// Get the count of tasks in active
    func taskCount() -> Int {
        return taskDict.count
    }
    
    /// Dump active tasks
    func dump() {
        slog("semaphore: \(self.semaphore)")
        for item in taskDict.keys {
            slog("downloading task: \(item)")
        }
    }
}

class DownloadTask {
    typealias Callback = (Data?) -> Void
    
    private var key: String
    private var _task: URLSessionDataTask
    private var callbacks : [Callback]
    
    init(url: URL, task: URLSessionDataTask, completion: @escaping Callback) {
        self.key = url.path
        self._task = task
        self.callbacks = [completion]
    }
    
    func add(callback: @escaping Callback) {
        callbacks.append(callback)
    }
    
    func notify(data: Data?) {
        for callback in callbacks {
            callback(data)
        }
    }
    
    func resume() {
        _task.resume()
    }
    
    func suspend() {
        _task.suspend()
    }
    
    func cancel() {
        _task.cancel()
    }
}

