//
//  MockingjayProtocol.swift
//  Mockingjay
//
//  Copyright (c) 2015, Kyle Fuller
//  All rights reserved.
//
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions are met:
//
//  * Redistributions of source code must retain the above copyright notice, this
//  list of conditions and the following disclaimer.
//
//  * Redistributions in binary form must reproduce the above copyright notice,
//  this list of conditions and the following disclaimer in the documentation
//  and/or other materials provided with the distribution.
//
//  * Neither the name of Mockingjay nor the names of its
//  contributors may be used to endorse or promote products derived from
//  this software without specific prior written permission.
//
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
//  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//  DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
//  FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
//  DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
//  SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
//  CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
//  OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
//  OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import Foundation


/// Structure representing a registered stub
public struct Stub : Equatable {
  let matcher:Matcher
  let builder:Builder
  let uuid:NSUUID
  
  init(matcher:Matcher, builder:Builder) {
    self.matcher = matcher
    self.builder = builder
    uuid = NSUUID()
  }
}

public func ==(lhs:Stub, rhs:Stub) -> Bool {
  return lhs.uuid == rhs.uuid
}

var stubs = [Stub]()

public class MockingjayProtocol : NSURLProtocol {
  // MARK: Stubs
  private var enableDownloading = true
  private let operationQueue = NSOperationQueue()
  
  class func addStub(stub:Stub) -> Stub {
    stubs.append(stub)
    
    var token: dispatch_once_t = 0
    dispatch_once(&token) {
      NSURLProtocol.registerClass(self)
      return
    }
    
    return stub
  }
  
  /// Register a matcher and a builder as a new stub
  public class func addStub(matcher:Matcher, builder:Builder) -> Stub {
    return addStub(Stub(matcher: matcher, builder: builder))
  }
  
  /// Unregister the given stub
  public class func removeStub(stub:Stub) {
    if let index = stubs.indexOf(stub) {
      stubs.removeAtIndex(index)
    }
  }
  
  /// Remove all registered stubs
  public class func removeAllStubs() {
    stubs.removeAll(keepCapacity: false)
  }
  
  /// Finds the appropriate stub for a request
  /// This method searches backwards though the registered requests
  /// to find the last registered stub that handles the request.
  class func stubForRequest(request:NSURLRequest) -> Stub? {
    for stub in stubs.reverse() {
      if stub.matcher(request) {
        return stub
      }
    }
    
    return nil
  }
  
  // MARK: NSURLProtocol
  
  /// Returns whether there is a registered stub handler for the given request.
  override public class func canInitWithRequest(request:NSURLRequest) -> Bool {
    return stubForRequest(request) != nil
  }
  
  override public class func canonicalRequestForRequest(request: NSURLRequest) -> NSURLRequest {
    return request
  }
  
  override public func startLoading() {
    if let stub = MockingjayProtocol.stubForRequest(request) {
      switch stub.builder(request) {
      case .Failure(let error):
        client?.URLProtocol(self, didFailWithError: error)
      case .Success(var response, let download):
        let headers = self.request.allHTTPHeaderFields
        
        switch(download) {
        case .Content(var data):
          applyRangeFromHTTPHeaders(headers, toData: &data, andUpdateResponse: &response)
          client?.URLProtocol(self, didLoadData: data)
          client?.URLProtocolDidFinishLoading(self)
        case .StreamContent(data: var data, inChunksOf: let bytes):
          applyRangeFromHTTPHeaders(headers, toData: &data, andUpdateResponse: &response)
          self.download(data, inChunksOfBytes: bytes)
          return
        case .NoContent:
          client?.URLProtocol(self, didReceiveResponse: response, cacheStoragePolicy: .NotAllowed)
          client?.URLProtocolDidFinishLoading(self)
        }
      }
    } else {
      let error = NSError(domain: NSInternalInconsistencyException, code: 0, userInfo: [ NSLocalizedDescriptionKey: "Handling request without a matching stub." ])
      client?.URLProtocol(self, didFailWithError: error)
    }
  }
  
  override public func stopLoading() {
    self.enableDownloading = false
    self.operationQueue.cancelAllOperations()
  }
  
  // MARK: Private Methods
  
  private func download(data:NSData?, inChunksOfBytes bytes:Int) {
    guard let data = data else {
      client?.URLProtocolDidFinishLoading(self)
      return
    }
    self.operationQueue.maxConcurrentOperationCount = 1
    self.operationQueue.addOperationWithBlock { () -> Void in
      self.download(data, fromOffset: 0, withMaxLength: bytes)
    }
  }
  
  
  private func download(data:NSData, fromOffset offset:Int, withMaxLength maxLength:Int) {
    guard let queue = NSOperationQueue.currentQueue() else {
      return
    }
    guard (offset < data.length) else {
      client?.URLProtocolDidFinishLoading(self)
      return
    }
    let length = min(data.length - offset, maxLength)
    
    queue.addOperationWithBlock { () -> Void in
      guard self.enableDownloading else {
        self.enableDownloading = true
        return
      }
      
      let subdata = data.subdataWithRange(NSMakeRange(offset, length))
      self.client?.URLProtocol(self, didLoadData: subdata)
      NSThread.sleepForTimeInterval(0.01)
      self.download(data, fromOffset: offset + length, withMaxLength: maxLength)
    }
  }
  
  private func extractRangeFromHTTPHeaders(headers:[String : String]?) -> NSRange? {
    guard let rangeStr = headers?["Range"] else {
      return nil
    }
    let range = rangeStr.componentsSeparatedByString("=")[1].componentsSeparatedByString("-").map({ (str) -> Int in
      Int(str)!
    })
    let loc = range[0]
    let length = range[1] - loc + 1
    return NSMakeRange(loc, length)
  }
  
  private func applyRangeFromHTTPHeaders(
    headers:[String : String]?,
    inout toData data:NSData,
    inout andUpdateResponse response:NSURLResponse) {
      guard let range = extractRangeFromHTTPHeaders(headers) else {
        client?.URLProtocol(self, didReceiveResponse: response, cacheStoragePolicy: .NotAllowed)
        return
      }
      let fullLength = data.length
      data = data.subdataWithRange(range)
      
      //Attach new headers to response
      if let r = response as? NSHTTPURLResponse {
        var header = r.allHeaderFields as! [String:String]
        header["Content-Length"] = String(data.length)
        header["Content-Range"] = String(range.httpRangeStringWithFullLength(fullLength))
        response = NSHTTPURLResponse(URL: r.URL!, statusCode: r.statusCode, HTTPVersion: nil, headerFields: header)!
      }
      
      client?.URLProtocol(self, didReceiveResponse: response, cacheStoragePolicy: .NotAllowed)
  }
  
}

extension NSRange {
  func httpRangeStringWithFullLength(fullLength:Int) -> String {
    let endLoc = self.location + self.length - 1
    return "bytes " + String(self.location) + "-" + String(endLoc) + "/" + String(fullLength)
  }
}