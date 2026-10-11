//
//  JavascriptAPIHttp.swift
//  iina
//
//  Created by Collider LI on 12/9/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Foundation
import JavaScriptCore
import Just

fileprivate typealias JustRequestFunc = (URLComponentsConvertible, [String : Any], [String : Any]) -> HTTPResult

@objc protocol JavascriptAPIHttpExportable: JSExport {
  func get(_ url: String, _ options: [String: Any]?) -> JSValue?
  func post(_ url: String, _ options: [String: Any]?) -> JSValue?
  func put(_ url: String, _ options: [String: Any]?) -> JSValue?
  func patch(_ url: String, _ options: [String: Any]?) -> JSValue?
  func request(_ method: String, _ url: String, _ options: [String: Any]?) -> JSValue?
  func delete(_ url: String, _ options: [String: Any]?) -> JSValue?
  func xmlrpc(_ location: String) -> JavascriptAPIXmlrpc?
  func download(_ url: String, _ dest: String, _ options: [String: Any]?) -> JSValue?
}

class JavascriptAPIHttp: JavascriptAPI, JavascriptAPIHttpExportable {

  @objc func get(_ url: String, _ options: [String: Any]?) -> JSValue? {
    return request(.get, url: url, options: options)
  }

  @objc func post(_ url: String, _ options: [String: Any]?) -> JSValue? {
    return request(.post, url: url, options: options)
  }

  @objc func put(_ url: String, _ options: [String: Any]?) -> JSValue? {
    return request(.put, url: url, options: options)
  }

  @objc func patch(_ url: String, _ options: [String: Any]?) -> JSValue? {
    return request(.patch, url: url, options: options)
  }

  @objc func delete(_ url: String, _ options: [String: Any]?) -> JSValue? {
    return request(.delete, url: url, options: options)
  }

  /// Any method Just does not know, including WebDAV PROPFIND. The password stays in a header.
  /// A URL that already contains a user or a password is rejected so this path does not record it.
  @objc func request(_ method: String, _ url: String, _ options: [String: Any]?) -> JSValue? {
    return whenPermitted(to: .networkRequest) {
      let verb = method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      guard Self.allowedMethods.contains(verb) else {
        throwError(withMessage: "HTTP method is not allowed.")
        return nil
      }
      guard hostIsValid(url) else {
        return JSValue(undefinedIn: context)
      }
      guard let target = URL(string: url), target.user == nil, target.password == nil else {
        throwError(withMessage: "The password belongs in a header, not in the URL.")
        return nil
      }
      let headers = stringHeaders(options?["headers"])
      let body = options?["body"] as? String
      let timeout = min(120, max(5, (options?["timeout"] as? NSNumber)?.doubleValue ?? 45))
      return createPromise { resolve, reject in
        var req = URLRequest(url: target, timeoutInterval: timeout)
        req.httpMethod = verb
        for (name, value) in headers {
          req.setValue(value, forHTTPHeaderField: name)
        }
        if let body {
          req.httpBody = Data(body.utf8)
        }
        let delegate = WebDAVRedirectDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        session.dataTask(with: req) { data, response, _ in
          let http = response as? HTTPURLResponse
          let tooLarge = (data?.count ?? 0) > 8_000_000
          let text = tooLarge ? "" : (data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
          let status = http?.statusCode ?? 0
          let reason: String
          if tooLarge {
            reason = "The response is too large."
          } else if http == nil {
            reason = "The server could not be reached."
          } else {
            reason = HTTPURLResponse.localizedString(forStatusCode: status)
          }
          let dict: [String: Any] = [
            "statusCode": status,
            "reason": reason,
            "text": text
          ]
          let ok = !tooLarge && (200...299).contains(status)
          DispatchQueue.main.async {
            (ok ? resolve : reject).call(withArguments: [dict])
            session.finishTasksAndInvalidate()
          }
        }.resume()
      }
    }
  }

  @objc func xmlrpc(_ location: String) -> JavascriptAPIXmlrpc? {
    guard hostIsValid(location) else {
      return nil
    }
    return JavascriptAPIXmlrpc(context: context, pluginInstance: pluginInstance, location: location)
  }

  func download(_ url: String, _ dest: String, _ options: [String: Any]?) -> JSValue? {
    return whenPermitted(to: .networkRequest) {
      guard hostIsValid(url) else {
        throwError(withMessage: "URL is not allowed.")
        return nil
      }
      guard let method = HTTPMethod(rawValue: options?["method"] as? String ?? "GET") else {
        throwError(withMessage: "method is invalid.")
        return nil
      }
      guard let destPath = self.parsePath(dest).path else {
        throwError(withMessage: "Not allowed to write to the destination.")
        return nil
      }
      let params = options?["params"] as? [String: String]
      let headers = options?["headers"] as? [String: String]
      let data = options?["data"] as? [String: Any]
      return createPromise { resolve, reject in
        Just.request(method, url: url,
                     params: params ?? [:],
                     data: data ?? [:],
                     headers: headers ?? [:],
                     asyncCompletionHandler:  { [unowned self] response in
          if (response.ok) {
            do {
              try response.content?.write(to: URL(fileURLWithPath: destPath))
            } catch {
              self.throwError(withMessage: "Unable to write to the destination.")
            }
            resolve.call(withArguments: [])
          } else {
            reject.call(withArguments: [response.toDict()])
          }
        })
      }
    }
  }

  private func request(_ method: HTTPMethod, url: String, options: [String: Any]?) -> JSValue? {
    return whenPermitted(to: .networkRequest) {
      // check host
      guard hostIsValid(url) else {
        return JSValue(undefinedIn: context)
      }
      // request
      let params = options?["params"] as? [String: String]
      let headers = options?["headers"] as? [String: String]
      let data = options?["data"] as? [String: Any]
      return createPromise { resolve, reject in
        Just.request(method, url: url,
                     params: params ?? [:],
                     data: data ?? [:],
                     headers: headers ?? [:],
                     asyncCompletionHandler:  { response in
          (response.ok ? resolve : reject).call(withArguments: [response.toDict()])
        })
      }
    }
  }

  private static let allowedMethods: Set<String> = [
    "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS",
    "PROPFIND", "PROPPATCH", "REPORT", "MKCOL", "COPY", "MOVE", "LOCK", "UNLOCK"
  ]

  private func stringHeaders(_ value: Any?) -> [String: String] {
    if let raw = value as? [String: String] { return raw }
    guard let raw = value as? [String: Any] else { return [:] }
    var headers: [String: String] = [:]
    for (name, item) in raw {
      if let text = item as? String {
        headers[name] = text
      }
    }
    return headers
  }

  private func hostIsValid(_ url: String) -> Bool {
    guard let urlComponents = URLComponents(string: url.addingPercentEncoding(withAllowedCharacters: .urlAllowed) ?? url) else {
      throwError(withMessage: "URL \(url) is invalid.")
      return false
    }
    guard pluginInstance.canAccess(url: urlComponents.url!) else {
      throwError(withMessage: "URL \(url) is not allowed.")
      return false
    }
    return true
  }
}

@objc protocol JavascriptAPIXmlrpcExportable: JSExport {
  func call(_ method: String, _ args: [Any]) -> JSValue?
}

class JavascriptAPIXmlrpc: JavascriptAPI, JavascriptAPIXmlrpcExportable {
  private let xmlrpc: JustXMLRPC

  init(context: JSContext, pluginInstance: JavascriptPluginInstance, location: String) {
    self.xmlrpc = JustXMLRPC(location)
    super.init(context: context, pluginInstance: pluginInstance)
  }

  @objc func call(_ method: String, _ args: [Any]) -> JSValue? {
    return createPromise { resolve, reject in
      self.xmlrpc.call(method, args) { response in
        switch response {
        case .ok(let returnValue):
          resolve.call(withArguments: [returnValue])
        case .failure:
          reject.call(withArguments: [])
        case .error(let err):
          reject.call(withArguments: [[
            "httpCode": err.httpCode,
            "reason": err.reason,
            "description": err.readableDescription,
          ] as [String: Any]])
        }
      }
    }
  }
}

/// Drops Authorization when a redirect leaves the host that was asked.
private final class WebDAVRedirectDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    var next = request
    let from = task.originalRequest?.url?.host
    let to = request.url?.host
    if let from, let to, from.caseInsensitiveCompare(to) != .orderedSame {
      next.setValue(nil, forHTTPHeaderField: "Authorization")
    }
    completionHandler(next)
  }
}

fileprivate extension HTTPResult {
  func toDict() -> [String: Any?] {
    return [
      "statusCode": statusCode,
      "reason": reason,
      "data": json,
      "text": text
    ]
  }
}
