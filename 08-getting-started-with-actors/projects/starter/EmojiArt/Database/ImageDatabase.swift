/// Copyright (c) 2024 Razeware LLC
/// 
/// Permission is hereby granted, free of charge, to any person obtaining a copy
/// of this software and associated documentation files (the "Software"), to deal
/// in the Software without restriction, including without limitation the rights
/// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
/// copies of the Software, and to permit persons to whom the Software is
/// furnished to do so, subject to the following conditions:
/// 
/// The above copyright notice and this permission notice shall be included in
/// all copies or substantial portions of the Software.
/// 
/// Notwithstanding the foregoing, you may not use, copy, modify, merge, publish,
/// distribute, sublicense, create a derivative work, and/or sell copies of the
/// Software in any work that is designed, intended, or marketed for pedagogical or
/// instructional purposes related to programming, coding, application development,
/// or information technology.  Permission for such use, copying, modification,
/// merger, publication, distribution, sublicensing, creation of derivative works,
/// or sale is expressly withheld.
/// 
/// This project and source code may use libraries or frameworks that are
/// released under various Open-Source licenses. Use of those libraries and
/// frameworks are governed by their own individual licenses.
///
/// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
/// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
/// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
/// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
/// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
/// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
/// THE SOFTWARE.

import UIKit

@globalActor actor ImageDatabase {
  static let shared = ImageDatabase()
  
  let imageLoader = ImageLoader()
  
  private var storage: DiskStorage!
  private var storedImagesIndex: [String] = []
  @MainActor private(set) var inDiskAccess: AsyncStream<Int>?
  
  private var inDiskAccessContinuation: AsyncStream<Int>.Continuation?
  private var inDiskAccessCounter = 0 {
    didSet { inDiskAccessContinuation?.yield(inDiskAccessCounter)
      
    }
  }
  
  deinit {
    inDiskAccessContinuation?.finish()
  }
  
  func setUp() async throws {
    storage = await DiskStorage()
    for fileURL in try await storage.persistedFiles() {
      storedImagesIndex.append(fileURL.lastPathComponent)
    }
    await imageLoader.setUp()
    
    let accessStream = AsyncStream<Int> { continuation in
      inDiskAccessContinuation = continuation
    }
    await MainActor.run {
      inDiskAccess = accessStream
    }
  }
  
  func clearInMemoryAssets() async {
    await imageLoader.clear()
  }
  
  func store(image: UIImage, forKey key: String) async throws {
    guard let data = image.pngData() else {
      throw "Could not save image \(key)"
    }
    let fileName = DiskStorage.fileName(for: key)
    try await storage.write(data, name: fileName)
    storedImagesIndex.append(fileName)
  }
  
  func image(_ key: String) async throws -> UIImage {
    if await imageLoader.cache.keys.contains(key) {
      print("Cached in-memory")
      return try await imageLoader.image(key)
    }
    
    do {
      // 1. get asset file name from DiskStorage and check database index for match
      // if key does not exist, throw and go to catch block to fetch asset from server
      let fileName = DiskStorage.fileName(for: key)
      if !storedImagesIndex.contains(fileName) {
        throw "Image not persisted"
      }
      
      // 2. Try reading the file from disk and initializing a UIImage with its contents
      // if this fails, throw and go to catch block
      let data = try await storage.read(name: fileName)
      guard let image = UIImage(data: data) else {
        throw "Invalid image data"
      }
      print("Cached on disk")
      inDiskAccessCounter += 1
      
      // 3. successfully retrieved cached image, store it in memory in ImageLoader
      // This prevents you from having to make the trip to the file system next time
      await imageLoader.add(image, forKey: key)
      return image
    } catch {
      // 4 fetch teh asset from the server
      let image = try await imageLoader.image(key)
      try await store(image: image, forKey: key)
      return image
    }
  }
  
  func clear() async {
    for name in storedImagesIndex {
      try? await storage.remove(name: name)
    }
    storedImagesIndex.removeAll()
  }
}
