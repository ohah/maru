import Foundation
import WebKit

struct MermaidExternalRequestAttempts {
    let fetch: UInt64
    let xhr: UInt64
    let webSocket: UInt64
    let eventSource: UInt64
    let cspViolation: UInt64

    var total: UInt64 { fetch + xhr + webSocket + eventSource + cspViolation }
    var isExactAPIProbe: Bool {
        fetch == 1 && xhr == 1 && webSocket == 1 && eventSource == 1 && cspViolation == 0
    }
}

struct MermaidRenderedPayload {
    let svg: String
    let externalRequests: MermaidExternalRequestAttempts
}

/// Helper 전용 WKWebView owner. native가 digest 검증한 번들 JS는 strict CSP 문서의 didFinish 뒤
/// page world에서 평가하므로 renderer document에는 app scheme, file base URL, message handler, bridge가 없다.
@MainActor
final class MermaidRendererPage: NSObject, WKNavigationDelegate {
    static let baseURL: URL? = nil
    static let maxScriptBytes = 8 * 1024 * 1024
    private static let externalRequestGuard = """
    (() => {
      const attempts = { fetch: 0, xhr: 0, webSocket: 0, eventSource: 0, cspViolation: 0 };
      const install = (name, value) => Object.defineProperty(globalThis, name, {
        value, writable: false, configurable: false, enumerable: false
      });
      try {
        install('fetch', (...args) => {
          void args;
          attempts.fetch += 1;
          return Promise.reject(new TypeError('external request blocked'));
        });
        install('XMLHttpRequest', class BlockedXMLHttpRequest {
          constructor() { attempts.xhr += 1; throw new TypeError('external request blocked'); }
        });
        install('WebSocket', class BlockedWebSocket {
          constructor() { attempts.webSocket += 1; throw new TypeError('external request blocked'); }
        });
        install('EventSource', class BlockedEventSource {
          constructor() { attempts.eventSource += 1; throw new TypeError('external request blocked'); }
        });
        globalThis.addEventListener('securitypolicyviolation', () => {
          attempts.cspViolation += 1;
        }, true);
        Object.defineProperty(globalThis, '__maruExternalRequestSnapshot', {
          value: () => Object.freeze({ ...attempts }),
          writable: false, configurable: false, enumerable: false
        });
      } catch (_) {
        // No snapshot means every render fails closed in mermaid-helper.ts.
      }
    })();
    """

    private(set) var externalNavigationAttempts: UInt64 = 0
    private let runtimeScript: String
    private let webView: WKWebView
    private var ready = false
    private var pending: [(String, (Result<MermaidRenderedPayload, Error>) -> Void)] = []
    private var readyCallbacks: [() -> Void] = []

    init?(script: String) {
        guard !script.isEmpty, script.utf8.count <= Self.maxScriptBytes else { return nil }
        runtimeScript = script
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Install only the non-configurable guard at document-start. The Mermaid runtime is evaluated
        // after didFinish so the first runtime byte also sees the document's parsed CSP.
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.externalRequestGuard, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        // userContentController에는 message handler를 하나도 추가하지 않는다.
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.loadHTMLString(
            """
            <!doctype html><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; connect-src 'none'; img-src data:; style-src 'unsafe-inline'">
            <body></body>
            """,
            baseURL: Self.baseURL
        )
    }

    func render(source: String, completion: @escaping (Result<MermaidRenderedPayload, Error>) -> Void) {
        guard ready else {
            pending.append((source, completion))
            return
        }
        evaluate(source: source, completion: completion)
    }

    func probeExternalRequests(completion: @escaping (MermaidExternalRequestAttempts?) -> Void) {
        guard ready else {
            readyCallbacks.append { [weak self] in self?.probeExternalRequests(completion: completion) }
            return
        }
        webView.callAsyncJavaScript(
            """
            try { await fetch('https://example.invalid/').catch(() => {}); } catch (_) {}
            try { new XMLHttpRequest(); } catch (_) {}
            try { new WebSocket('wss://example.invalid/'); } catch (_) {}
            try { new EventSource('https://example.invalid/'); } catch (_) {}
            return window.__maruExternalRequestSnapshot?.();
            """,
            arguments: [:],
            in: nil,
            in: .page
        ) { result in
            guard case let .success(value) = result else { completion(nil); return }
            completion(Self.requestAttempts(value))
        }
    }

    func probeExternalNavigation(completion: @escaping (Bool) -> Void) {
        guard ready else {
            readyCallbacks.append { [weak self] in self?.probeExternalNavigation(completion: completion) }
            return
        }
        guard let url = URL(string: "https://example.invalid/") else { completion(false); return }
        let before = externalNavigationAttempts
        webView.load(URLRequest(url: url))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            completion(self.externalNavigationAttempts == before + 1)
        }
    }

    func probeExternalSubresource(completion: @escaping (MermaidExternalRequestAttempts?) -> Void) {
        guard ready else {
            readyCallbacks.append { [weak self] in self?.probeExternalSubresource(completion: completion) }
            return
        }
        webView.callAsyncJavaScript(
            """
            const image = document.createElement('img');
            image.src = 'https://example.invalid/probe.png';
            document.body.appendChild(image);
            await new Promise((resolve) => setTimeout(resolve, 100));
            image.remove();
            return window.__maruExternalRequestSnapshot?.();
            """,
            arguments: [:],
            in: nil,
            in: .page
        ) { result in
            guard case let .success(value) = result else { completion(nil); return }
            completion(Self.requestAttempts(value))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !ready else { return }
        webView.evaluateJavaScript(runtimeScript) { [weak self] _, _ in
            guard let self else { return }
            // A runtime evaluation error still releases queued operations; normal render then fails
            // through the missing/invalid __maruRenderMermaid call instead of hanging to deadline.
            self.ready = true
            let queued = self.pending
            self.pending.removeAll(keepingCapacity: true)
            for (source, completion) in queued { self.evaluate(source: source, completion: completion) }
            let callbacks = self.readyCallbacks
            self.readyCallbacks.removeAll(keepingCapacity: true)
            for callback in callbacks { callback() }
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url,
           !(url.scheme == "about" && url.absoluteString == "about:blank") {
            externalNavigationAttempts += 1
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    private func evaluate(source: String, completion: @escaping (Result<MermaidRenderedPayload, Error>) -> Void) {
        let navigationAttemptsBefore = externalNavigationAttempts
        webView.callAsyncJavaScript(
            "return await window.__maruRenderMermaid(source)",
            arguments: ["source": source],
            in: nil,
            in: .page
        ) { result in
            switch result {
            case let .success(value):
                guard let dictionary = value as? [String: Any],
                      let svg = dictionary["svg"] as? String,
                      let attempts = Self.requestAttempts(dictionary["externalRequests"]),
                      attempts.total == 0,
                      self.externalNavigationAttempts == navigationAttemptsBefore else {
                    completion(.failure(RenderError.invalidResult))
                    return
                }
                completion(.success(MermaidRenderedPayload(svg: svg, externalRequests: attempts)))
            case let .failure(error):
                completion(.failure(error))
            }
        }
    }

    private enum RenderError: Error {
        case invalidResult
        case externalRequestAttempt
    }

    private static func requestAttempts(_ value: Any?) -> MermaidExternalRequestAttempts? {
        guard let dictionary = value as? [String: Any],
              let fetch = (dictionary["fetch"] as? NSNumber)?.uint64Value,
              let xhr = (dictionary["xhr"] as? NSNumber)?.uint64Value,
              let webSocket = (dictionary["webSocket"] as? NSNumber)?.uint64Value,
              let eventSource = (dictionary["eventSource"] as? NSNumber)?.uint64Value,
              let cspViolation = (dictionary["cspViolation"] as? NSNumber)?.uint64Value else { return nil }
        return MermaidExternalRequestAttempts(
            fetch: fetch,
            xhr: xhr,
            webSocket: webSocket,
            eventSource: eventSource,
            cspViolation: cspViolation
        )
    }
}
