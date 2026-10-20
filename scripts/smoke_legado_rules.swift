// Local macOS WebKit runner for smoke_legado_rules.py. No remote navigation.
import AppKit
import Foundation
import WebKit

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

Task { @MainActor in
    do {
        guard CommandLine.arguments.count == 3 else {
            print("{\"runnerError\":\"arguments\"}")
            app.terminate(nil)
            return
        }
        let rules = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let fixtures = try JSONSerialization.jsonObject(with: data)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        let harness = #"""
        const html = '<html><head><meta property="og:novel:author" content="合成作者"></head><body><main><div><p><span><a href="/synthetic">合成内容</a></span></p></div></main></body></html>';
        const json = '{"data":[],"items":[],"books":[],"chapters":[]}';
        let blockedScriptCalls = 0;
        const forbidden = () => { blockedScriptCalls++; throw Error('SMOKE_BLOCKED_DYNAMIC_RULE'); };
        const env = {baseURL:'https://fixture.invalid/',evalJS:forbidden,getVar:forbidden,putVar:forbidden};
        const errors = [];
        let errorCount = 0;
        function category(error) {
            const message = String(error && error.message || '');
            if (message.includes('SMOKE_BLOCKED')) return 'dynamic_rule_excluded';
            if (message.includes('CSS')) return 'css_syntax';
            if (message.includes('XPath')) return 'xpath_syntax';
            if (message.includes('JSON')) return 'jsonpath_syntax_or_context';
            if (message.includes('正则')) return 'regex_syntax';
            if (message.includes('索引') || message.includes('切片')) return 'index_syntax';
            if (message.includes('括号') || message.includes('结束符')) return 'unbalanced_delimiters';
            if (message.includes('上限') || message.includes('过深')) return 'evaluation_limit';
            return 'rule_error';
        }
        for (const fixture of fixtures) {
            try {
                LegadoRules.extract(fixture.context === 'json' ? json : html, fixture.rule, env, fixture.mode);
            } catch (error) {
                errorCount++;
                if (errors.length < 100) errors.push({sourceIndex:fixture.sourceIndex,section:fixture.section,field:fixture.field,category:category(error)});
            }
        }
        return JSON.stringify({tested:fixtures.length,errorCount,blockedScriptCalls,errors,errorsTruncated:errorCount > errors.length});
        """#
        let output = try await view.callAsyncJavaScript(rules + "\n" + harness, arguments: ["fixtures": fixtures], in: nil, contentWorld: .page)
        if let text = output as? String { print(text) }
        else { print("{\"runnerError\":\"output\"}") }
    } catch {
        // Do not emit WebKit exceptions, which could contain source expressions.
        print("{\"runnerError\":\"execution\"}")
    }
    app.terminate(nil)
}

app.run()
