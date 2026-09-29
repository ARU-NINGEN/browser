import SwiftUI
import WebKit
import Translation
import UserNotifications

// MARK: - モデル

struct Tab: Identifiable, Equatable {
    let id = UUID()
    var webView: WKWebView
    var urlString: String = ""
    var pageTitle: String = ""
    var canGoBack: Bool = false
    var canGoForward: Bool = false
}

struct Bookmark: Identifiable, Codable, Equatable {
    let id = UUID()
    var title: String
    var urlString: String
}

struct NetworkLog: Identifiable {
    let id = UUID()
    let url: String
    let type: String
}

struct StorageItem: Identifiable {
    let id = UUID()
    let key: String
    let value: String
}

// MARK: - ViewModel

class WebViewModel: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler, UNUserNotificationCenterDelegate {
    @Published var tabs: [Tab] = []
    @Published var selectedTabId: UUID?
    
    @Published var bookmarks: [Bookmark] = []
    @Published var showBookmarksSheet: Bool = false
    
    @Published var consoleLogs: [String] = []
    @Published var networkLogs: [NetworkLog] = []
    @Published var storageItems: [StorageItem] = []
    @Published var pageSource: String = ""
    @Published var showDevToolsSheet: Bool = false
    
    @Published var isTranslationEnabled: Bool = false
    @Published var translatedPageText: String = ""
    @Published var isTranslating: Bool = false
    @Published var showTranslationSheet: Bool = false
    @Published var translationConfiguration: TranslationSession.Configuration?
    
    @Published var currentWindowWidth: CGFloat = 1024
    
    // ★ Lumina 5.0: 偽装モード（true: Safariなりすまし, false: Lumina独自）
    @Published var isSpoofingEnabled: Bool = true {
        didSet {
            updateAllWebViewsUserAgent()
        }
    }
    
    // 動的にOSバージョンを取得するUA生成プロパティ
    var mobileUA: String {
        let osVersion = UIDevice.current.systemVersion
        let osVersionUnderscore = osVersion.replacingOccurrences(of: ".", with: "_")
        if isSpoofingEnabled {
            return "Mozilla/5.0 (iPhone; CPU OS \(osVersionUnderscore) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(osVersion) Mobile/15E148 Safari/604.1"
        } else {
            return "Mozilla/5.0 (iPhone; CPU OS \(osVersionUnderscore) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(osVersion) Mobile/15E148 Safari/604.1 Lumina/5.0"
        }
    }
    
    var desktopUA: String {
        let osVersion = UIDevice.current.systemVersion
        if isSpoofingEnabled {
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(osVersion) Safari/605.1.15"
        } else {
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(osVersion) Safari/605.1.15 Lumina/5.0"
        }
    }
    
    override init() {
        super.init()
        loadBookmarks()
        requestNotificationPermission()
        addNewTab()
    }
    
    // 通知権限のリクエスト
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("通知許可が得られました")
            } else if let error = error {
                print("通知許可エラー: \(error.localizedDescription)")
            }
        }
    }
    
    // フォアグラウンドでも通知を表示するためのデリゲート
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }
    
    var currentTab: Tab? {
        tabs.first(where: { $0.id == selectedTabId })
    }
    
    var currentWebView: WKWebView? {
        currentTab?.webView
    }
    
    var isCurrentPageBookmarked: Bool {
        guard let currentURL = currentTab?.urlString else { return false }
        return bookmarks.contains(where: { $0.urlString == currentURL })
    }
    
    func toggleBookmark() {
        guard let currentURL = currentTab?.urlString, !currentURL.isEmpty else { return }
        let title = currentWebView?.title ?? currentURL
        
        if let index = bookmarks.firstIndex(where: { $0.urlString == currentURL }) {
            bookmarks.remove(at: index)
        } else {
            bookmarks.append(Bookmark(title: title, urlString: currentURL))
        }
        saveBookmarks()
    }
    
    private func saveBookmarks() {
        if let encoded = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(encoded, forKey: "SavedBookmarks")
        }
    }
    
    private func loadBookmarks() {
        if let data = UserDefaults.standard.data(forKey: "SavedBookmarks"),
           let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) {
            bookmarks = decoded
        }
    }
    
    func addNewTab(urlString: String = "https://www.google.com") {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        
        let userContentController = WKUserContentController()
        userContentController.add(self, name: "consoleBridge")
        userContentController.add(self, name: "networkBridge")
        userContentController.add(self, name: "notificationBridge")
        
        let devToolsScript = WKUserScript(
            source: """
            if (!window.devToolsInjected) {
                window.devToolsInjected = true;
                
                var originalLog = console.log;
                console.log = function(...args) {
                    originalLog.apply(console, args);
                    window.webkit.messageHandlers.consoleBridge.postMessage(args.map(arg => typeof arg === 'object' ? JSON.stringify(arg) : arg).join(' '));
                };
                var originalError = console.error;
                console.error = function(...args) {
                    originalError.apply(console, args);
                    window.webkit.messageHandlers.consoleBridge.postMessage('[Error] ' + args.map(arg => typeof arg === 'object' ? JSON.stringify(arg) : arg).join(' '));
                };
            
                const originalFetch = window.fetch;
                window.fetch = async function(...args) {
                    const url = typeof args[0] === 'string' ? args[0] : args[0].url;
                    window.webkit.messageHandlers.networkBridge.postMessage(JSON.stringify({url: url, type: 'Fetch'}));
                    return originalFetch.apply(this, args);
                };
            
                const originalOpen = XMLHttpRequest.prototype.open;
                XMLHttpRequest.prototype.open = function(method, url) {
                    window.webkit.messageHandlers.networkBridge.postMessage(JSON.stringify({url: url, type: 'XHR'}));
                    originalOpen.apply(this, arguments);
                };
            
                // Webサイトからの Notification API をネイティブに転送
                window.Notification = class {
                    constructor(title, options) {
                        this.title = title;
                        this.options = options || {};
                        window.webkit.messageHandlers.notificationBridge.postMessage(JSON.stringify({
                            title: this.title,
                            body: this.options.body || ''
                        }));
                    }
                    static get permission() {
                        return 'granted';
                    }
                    static requestPermission(callback) {
                        if (callback) callback('granted');
                        return Promise.resolve('granted');
                    }
                };
            }
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        userContentController.addUserScript(devToolsScript)
        config.userContentController = userContentController
        
        let webView = WKWebView(frame: .zero, configuration: config)
        
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        
        let isDesktop = currentWindowWidth >= 768
        webView.customUserAgent = isDesktop ? desktopUA : mobileUA
        
        let tab = Tab(webView: webView)
        webView.navigationDelegate = self
        tabs.append(tab)
        selectedTabId = tab.id
        
        loadUrl(urlString)
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "consoleBridge", let logMessage = message.body as? String {
            DispatchQueue.main.async {
                self.consoleLogs.append(logMessage)
            }
        } else if message.name == "networkBridge", let jsonString = message.body as? String {
            if let data = jsonString.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               let url = dict["url"], let type = dict["type"] {
                DispatchQueue.main.async {
                    self.networkLogs.append(NetworkLog(url: url, type: type))
                }
            }
        } else if message.name == "notificationBridge", let jsonString = message.body as? String {
            if let data = jsonString.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               let title = dict["title"], let body = dict["body"] {
                triggerLocalNotification(title: title, body: body)
            }
        }
    }
    
    // iOSのローカル通知を発火させる処理
    private func triggerLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("通知送信エラー: \(error.localizedDescription)")
            }
        }
    }
    
    func removeTab(id: UUID) {
        tabs.removeAll(where: { $0.id == id })
        if tabs.isEmpty { addNewTab() }
        else if selectedTabId == id { selectedTabId = tabs.first?.id }
    }
    
    func loadUrl(_ urlString: String) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == selectedTabId }) else { return }
        var urlStr = urlString
        if let url = URL(string: urlString), url.scheme == nil {
            urlStr = "https://\(urlString)"
        }
        if let url = URL(string: urlStr) {
            tabs[tabIndex].urlString = urlStr
            let request = URLRequest(url: url)
            tabs[tabIndex].webView.load(request)
        }
    }
    
    func updateLayoutMode(width: CGFloat) {
        currentWindowWidth = width
        let isDesktop = width >= 768
        let targetUA = isDesktop ? desktopUA : mobileUA
        
        guard let webView = currentWebView else { return }
        if webView.customUserAgent != targetUA {
            webView.customUserAgent = targetUA
            webView.reload()
        }
    }
    
    // モード変更時にすべてのタブのUAを更新してリロードする
    private func updateAllWebViewsUserAgent() {
        let isDesktop = currentWindowWidth >= 768
        let targetUA = isDesktop ? desktopUA : mobileUA
        for tab in tabs {
            tab.webView.customUserAgent = targetUA
            tab.webView.reload()
        }
    }
    
    func restoreKeyboardFocus() {
        guard let webView = currentWebView else { return }
        webView.resignFirstResponder()
        webView.becomeFirstResponder()
    }
    
    func goBack() { currentWebView?.goBack() }
    func goForward() { currentWebView?.goForward() }
    
    func fetchPageSource() {
        currentWebView?.evaluateJavaScript("document.documentElement.outerHTML.toString()") { result, error in
            if let html = result as? String {
                DispatchQueue.main.async {
                    self.pageSource = html
                }
            } else if let error = error {
                DispatchQueue.main.async {
                    self.pageSource = "取得エラー: \(error.localizedDescription)"
                }
            }
        }
    }
    
    func fetchLocalStorage() {
        currentWebView?.evaluateJavaScript("""
            (() => {
                let items = [];
                for (let i = 0; i < localStorage.length; i++) {
                    let key = localStorage.key(i);
                    items.push({key: key, value: localStorage.getItem(key)});
                }
                return JSON.stringify(items);
            })();
            """) { result, _ in
            if let jsonString = result as? String,
               let data = jsonString.data(using: .utf8),
               let array = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
                DispatchQueue.main.async {
                    self.storageItems = array.map { StorageItem(key: $0["key"] ?? "", value: $0["value"] ?? "") }
                }
            }
        }
    }
    
    func extractPageTexts(completion: @escaping ([String]) -> Void) {
        let script = """
        (() => {
            let texts = [];
            function walk(node) {
                if (node.nodeType === Node.TEXT_NODE) {
                    let text = node.nodeValue.trim();
                    if (text.length > 0 && node.parentNode.tagName !== 'SCRIPT' && node.parentNode.tagName !== 'STYLE') {
                        texts.push(text);
                    }
                } else {
                    for (let child of node.childNodes) {
                        walk(child);
                    }
                }
            }
            walk(document.body);
            return texts;
        })();
        """
        currentWebView?.evaluateJavaScript(script) { result, _ in
            if let array = result as? [String] {
                completion(array)
            } else {
                completion([])
            }
        }
    }
    
    func applyTranslatedTexts(_ translatedMap: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: translatedMap),
              let jsonString = String(data: data, encoding: .utf8) else { return }
        
        let script = """
        (() => {
            const map = \(jsonString);
            function walk(node) {
                if (node.nodeType === Node.TEXT_NODE) {
                    let text = node.nodeValue.trim();
                    if (map[text]) {
                        node.nodeValue = node.nodeValue.replace(text, map[text]);
                    }
                } else {
                    for (let child of node.childNodes) {
                        walk(child);
                    }
                }
            }
            walk(document.body);
        })();
        """
        currentWebView?.evaluateJavaScript(script, completionHandler: nil)
    }
    
    func executeJavaScript(_ script: String, completion: @escaping (String) -> Void) {
        currentWebView?.evaluateJavaScript(script) { result, error in
            if let error = error {
                completion("エラー: \(error.localizedDescription)")
            } else if let result = result {
                completion("\(result)")
            } else {
                completion("成功 (戻り値なし)")
            }
        }
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let isDesktop = currentWindowWidth >= 768
        let targetUA = isDesktop ? desktopUA : mobileUA
        if webView.customUserAgent != targetUA {
            webView.customUserAgent = targetUA
            webView.reload()
            return
        }
        
        if let index = tabs.firstIndex(where: { $0.webView == webView }) {
            DispatchQueue.main.async {
                self.tabs[index].urlString = webView.url?.absoluteString ?? ""
                self.tabs[index].pageTitle = webView.title ?? "無題のページ"
                self.tabs[index].canGoBack = webView.canGoBack
                self.tabs[index].canGoForward = webView.canGoForward
                self.fetchPageSource()
                self.fetchLocalStorage()
            }
        }
    }
}

// MARK: - WebViewラッパー

struct SingleWebViewWrapper: UIViewRepresentable {
    let webView: WKWebView
    
    func makeUIView(context: Context) -> WKWebView {
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Liquid Glass風背景エフェクト

struct LiquidGlassBackground: View {
    @State private var animate = false
    
    var body: some View {
        LinearGradient(
            colors: [Color.blue.opacity(0.3), Color.purple.opacity(0.2), Color.cyan.opacity(0.25)],
            startPoint: animate ? .topLeading : .bottomLeading,
            endPoint: animate ? .bottomTrailing : .topTrailing
        )
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) {
                animate.toggle()
            }
        }
    }
}

// MARK: - ブックマーク一覧画面

struct BookmarksView: View {
    @ObservedObject var webVM: WebViewModel
    
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                HStack {
                    Text("ブックマーク")
                        .font(.headline)
                        .padding()
                    Spacer()
                    Button("閉じる") {
                        webVM.showBookmarksSheet = false
                    }
                    .padding()
                }
                .background(.thinMaterial)
                
                List {
                    ForEach(webVM.bookmarks) { bookmark in
                        Button(action: {
                            webVM.loadUrl(bookmark.urlString)
                            webVM.showBookmarksSheet = false
                        }) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(bookmark.title)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text(bookmark.urlString)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        webVM.bookmarks.remove(atOffsets: indexSet)
                    }
                    .listRowBackground(Color.white.opacity(0.1))
                }
                .scrollContentBackground(.hidden)
            }
        }
        .cornerRadius(16)
        .shadow(radius: 10)
    }
}

// MARK: - 翻訳結果表示画面

struct TranslationView: View {
    @ObservedObject var webVM: WebViewModel
    
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                HStack {
                    Text("ページ翻訳")
                        .font(.headline)
                        .padding()
                    Spacer()
                    Button("閉じる") {
                        webVM.showTranslationSheet = false
                        webVM.translationConfiguration = nil
                    }
                    .padding()
                }
                .background(.thinMaterial)
                
                VStack(alignment: .leading, spacing: 10) {
                    Text(webVM.isTranslating ? "Webページを翻訳中..." : "翻訳が完了しました。レイアウトを維持してページを日本語化しました。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    ScrollView {
                        Text(webVM.translatedPageText.isEmpty ? "テキストを解析中..." : webVM.translatedPageText)
                            .font(.system(.body, design: .default))
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
                    .frame(maxHeight: .infinity)
                }
                .padding()
            }
        }
        .cornerRadius(16)
        .shadow(radius: 10)
        .translationTask(webVM.translationConfiguration) { session in
            do {
                DispatchQueue.main.async {
                    webVM.isTranslating = true
                    webVM.translatedPageText = "ページ内のテキストを抽出・翻訳しています..."
                }
                
                webVM.extractPageTexts { originalTextsArray in
                    let uniqueTexts = Array(Set(originalTextsArray)).filter { !$0.isEmpty }
                    
                    Task {
                        var translatedMap: [String: String] = [:]
                        var summaryText = ""
                        
                        for text in uniqueTexts {
                            do {
                                let response = try await session.translate(text)
                                translatedMap[text] = response.targetText
                                summaryText += "【原文】: \(text)\n【訳文】: \(response.targetText)\n\n"
                            } catch {
                                // 個別の翻訳失敗はスキップ
                            }
                        }
                        
                        DispatchQueue.main.async {
                            webVM.applyTranslatedTexts(translatedMap)
                            webVM.translatedPageText = summaryText.isEmpty ? "翻訳できるテキストが見つかりませんでした。" : summaryText
                            webVM.isTranslating = false
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    webVM.translatedPageText = "翻訳エラー: \(error.localizedDescription)"
                    webVM.isTranslating = false
                }
            }
        }
    }
}

// MARK: - 開発者ツール 各タブのパーツ分割

struct ElementsTabView: View {
    @ObservedObject var webVM: WebViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("DOM / HTML ソース").font(.subheadline).bold()
                Spacer()
                Button("再取得") {
                    webVM.fetchPageSource()
                }
                .font(.caption)
            }
            
            ScrollView {
                Text(webVM.pageSource.isEmpty ? "データなし" : webVM.pageSource)
                    .font(.system(.caption, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .background(.ultraThinMaterial)
            .cornerRadius(10)
        }
        .padding()
        .background(.thinMaterial)
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

struct ConsoleTabView: View {
    @ObservedObject var webVM: WebViewModel
    @Binding var jsInput: String
    @Binding var jsOutput: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("コンソールログ").font(.subheadline).bold()
                Spacer()
                Button("クリア") {
                    webVM.consoleLogs.removeAll()
                }
                .font(.caption)
            }
            
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(webVM.consoleLogs.enumerated()), id: \.offset) { _, log in
                        Text(log)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.primary)
                            .padding(.vertical, 2)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(.ultraThinMaterial)
            .cornerRadius(10)
            .frame(maxHeight: 120)
            
            Text("JavaScript手動実行").font(.subheadline).bold()
            HStack {
                TextField("例: console.log('test');", text: $jsInput)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                
                Button("実行") {
                    webVM.executeJavaScript(jsInput) { output in
                        jsOutput = output
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            
            Text("結果: \(jsOutput)")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
        .padding()
        .background(.thinMaterial)
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

struct NetworkTabView: View {
    @ObservedObject var webVM: WebViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ネットワークリクエスト (Fetch/XHR)").font(.subheadline).bold()
                Spacer()
                Button("クリア") {
                    webVM.networkLogs.removeAll()
                }
                .font(.caption)
            }
            
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(webVM.networkLogs) { log in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("[\(log.type)]")
                                .font(.system(.caption2, design: .monospaced))
                                .bold()
                                .foregroundColor(.orange)
                            Text(log.url)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.primary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                        .padding(6)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(.ultraThinMaterial)
            .cornerRadius(10)
        }
        .padding()
        .background(.thinMaterial)
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

struct ApplicationTabView: View {
    @ObservedObject var webVM: WebViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LocalStorage 一覧").font(.subheadline).bold()
                Spacer()
                Button("再読み込み") {
                    webVM.fetchLocalStorage()
                }
                .font(.caption)
            }
            
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(webVM.storageItems) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Key: \(item.key)")
                                .font(.system(.caption2, design: .monospaced))
                                .bold()
                                .foregroundColor(.blue)
                                .textSelection(.enabled)
                            Text("Value: \(item.value)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                        }
                        .padding(6)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(.ultraThinMaterial)
            .cornerRadius(10)
        }
        .padding()
        .background(.thinMaterial)
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

// MARK: - 開発者ツール画面メイン

struct DevToolsView: View {
    @ObservedObject var webVM: WebViewModel
    @State private var jsInput: String = "document.title"
    @State private var jsOutput: String = ""
    @State private var selectedTab: Int = 0
    
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                HStack {
                    Text("開発者ツール")
                        .font(.headline)
                        .padding()
                    Spacer()
                    Button("閉じる") {
                        webVM.showDevToolsSheet = false
                    }
                    .padding()
                }
                .background(.thinMaterial)
                
                ScrollView(.horizontal, showsIndicators: false) {
                    Picker("モード", selection: $selectedTab) {
                        Text("ソースコード").tag(0)
                        Text("コンソール").tag(1)
                        Text("ネットワーク").tag(2)
                        Text("アプリ").tag(3)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding(.horizontal)
                }
                .padding(.top, 8)
                
                VStack(spacing: 16) {
                    if selectedTab == 0 {
                        ElementsTabView(webVM: webVM)
                    } else if selectedTab == 1 {
                        ConsoleTabView(webVM: webVM, jsInput: $jsInput, jsOutput: $jsOutput)
                    } else if selectedTab == 2 {
                        NetworkTabView(webVM: webVM)
                    } else {
                        ApplicationTabView(webVM: webVM)
                    }
                    
                    Spacer()
                }
                .padding(.top, 8)
            }
        }
        .cornerRadius(16)
        .shadow(radius: 10)
    }
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject var webVM = WebViewModel()
    @State private var inputText: String = ""
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let isShowingSubPanel = webVM.showBookmarksSheet || webVM.showDevToolsSheet || webVM.showTranslationSheet
            
            ZStack {
                LiquidGlassBackground()
                
                if isLandscape {
                    HStack(spacing: 0) {
                        mainBrowserView
                            .frame(width: isShowingSubPanel ? geometry.size.width * (2/3) : geometry.size.width)
                        
                        if isShowingSubPanel {
                            subPanelView
                                .frame(width: geometry.size.width * (1/3))
                                .transition(.move(edge: .trailing))
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        mainBrowserView
                            .frame(height: isShowingSubPanel ? geometry.size.height * 0.5 : geometry.size.height)
                        
                        if isShowingSubPanel {
                            subPanelView
                                .frame(height: geometry.size.height * 0.5)
                                .transition(.move(edge: .bottom))
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.3), value: isShowingSubPanel)
            .onChange(of: geometry.size.width) { newWidth in
                webVM.updateLayoutMode(width: newWidth)
            }
            .onAppear {
                inputText = webVM.currentTab?.urlString ?? ""
                webVM.updateLayoutMode(width: geometry.size.width)
            }
            .onChange(of: webVM.selectedTabId) { _ in
                inputText = webVM.currentTab?.urlString ?? ""
            }
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .active {
                    webVM.restoreKeyboardFocus()
                }
            }
        }
    }
    
    var mainBrowserView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: { webVM.goBack() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                }
                .disabled(!(webVM.currentTab?.canGoBack ?? false))
                .buttonStyle(.bordered)
                .tint(.primary)
                
                Button(action: { webVM.goForward() }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                }
                .disabled(!(webVM.currentTab?.canGoForward ?? false))
                .buttonStyle(.bordered)
                .tint(.primary)
                
                TextField("URLを入力", text: $inputText, onCommit: {
                    webVM.loadUrl(inputText)
                })
                .textFieldStyle(.plain)
                .padding(10)
                .background(.ultraThinMaterial)
                .cornerRadius(12)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                
                Button(action: {
                    webVM.toggleBookmark()
                }) {
                    Image(systemName: webVM.isCurrentPageBookmarked ? "star.fill" : "star")
                        .foregroundColor(webVM.isCurrentPageBookmarked ? .yellow : .primary)
                }
                .buttonStyle(.bordered)
                
                // ブックマーク一覧ボタン
                Button(action: {
                    webVM.showDevToolsSheet = false
                    webVM.showTranslationSheet = false
                    webVM.showBookmarksSheet.toggle()
                }) {
                    Image(systemName: "book.closed.fill")
                        .foregroundColor(.blue)
                }
                .buttonStyle(.bordered)
                
                // 翻訳ボタン
                Button(action: {
                    webVM.showBookmarksSheet = false
                    webVM.showDevToolsSheet = false
                    webVM.translationConfiguration = TranslationSession.Configuration(source: nil, target: Locale.Language(identifier: "ja"))
                    webVM.showTranslationSheet.toggle()
                }) {
                    Image(systemName: "globe")
                        .foregroundColor(.green)
                }
                .buttonStyle(.bordered)
                
                // 開発者ツールボタン
                Button(action: {
                    webVM.showBookmarksSheet = false
                    webVM.showTranslationSheet = false
                    webVM.fetchPageSource()
                    webVM.fetchLocalStorage()
                    webVM.showDevToolsSheet.toggle()
                }) {
                    Image(systemName: "hammer.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundColor(.orange)
                }
                .buttonStyle(.bordered)
                
                // ★ 開発者ツールボタンの右側：Safari/Luminaモード切り替えボタン
                Button(action: {
                    webVM.isSpoofingEnabled.toggle()
                }) {
                    if webVM.isSpoofingEnabled {
                        // Safariなりすましモード中なら「Safariアイコン」を表示（タップするとLuminaモードになる）
                        Image("Safariアイコン")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                    } else {
                        // Lumina独自モード中なら「Luminaアイコン」を表示（タップするとSafariモードになる）
                        Image("Luminaアイコン")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                    }
                }
                .buttonStyle(.bordered)
                .help(webVM.isSpoofingEnabled ? "Safariなりすましモード (タップでLuminaモードに変更)" : "Lumina独自モード (タップでSafariなりすましに変更)")
            }
            .padding()
            .background(.ultraThinMaterial)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(webVM.tabs) { tab in
                        HStack(spacing: 6) {
                            Button(action: {
                                webVM.selectedTabId = tab.id
                                inputText = tab.urlString
                            }) {
                                Text(tab.pageTitle.isEmpty ? "新しいタブ" : tab.pageTitle)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(webVM.selectedTabId == tab.id ? Color.white.opacity(0.4) : Color.clear)
                                    .cornerRadius(8)
                            }
                            
                            Button(action: { webVM.removeTab(id: tab.id) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(6)
                        .background(.thinMaterial)
                        .cornerRadius(10)
                    }
                    
                    Button(action: {
                        webVM.addNewTab()
                        inputText = webVM.currentTab?.urlString ?? ""
                    }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .padding(.leading, 4)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(.ultraThinMaterial)
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(.white.opacity(0.3)),
                alignment: .bottom
            )
            .frame(height: 52)
            
            ZStack {
                ForEach(webVM.tabs) { tab in
                    if tab.id == webVM.selectedTabId {
                        SingleWebViewWrapper(webView: tab.webView)
                            .edgesIgnoringSafeArea(.bottom)
                    }
                }
            }
            .background(Color.clear)
        }
    }
    
    @ViewBuilder
    var subPanelView: some View {
        if webVM.showBookmarksSheet {
            BookmarksView(webVM: webVM)
        } else if webVM.showDevToolsSheet {
            DevToolsView(webVM: webVM)
        } else if webVM.showTranslationSheet {
            TranslationView(webVM: webVM)
        }
    }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
