#!/usr/bin/env python3
"""A local, dependency-free book-source fixture. Run: python3 scripts/demo_source_server.py."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
import json
import threading
import time

CHAPTERS = [
    {"title": "第一章 春日读书", "url": "/chapters/1"},
    {"title": "第二章 雨后散步", "url": "/chapters/2"},
]
TEXT = {
    "/chapters/1": "第一章 春日读书\n\n窗边的光落在书页上。翻开一本书，就像推开一扇安静的门。\n\n这是阅读应用的本地测试内容，用来验证书源搜索、目录解析、章节下载与离线缓存。\n\n你可以添加书签，修改字号，然后返回书架。下次打开时，阅读位置会保留下来。",
    "/chapters/2": "第二章 雨后散步\n\n雨停了，树叶上还挂着细小的水珠。街道像洗过一样，连脚步也轻了。\n\n这一章由本地测试服务提供。成功读到这里，说明书源、目录和正文的连接已经完成。",
}


class Handler(BaseHTTPRequestHandler):
    polish_toc_requests = 0
    background_lock = threading.Lock()
    background_completed = []
    background_offline = False
    background_generation = 0
    background_denied = 0

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query).get("q", [""])[0]
        background_chapter = None
        background_generation = None
        if parsed.path == "/background-cookie-redirect":
            self.send_response(302)
            self.send_header("Location", "/background-cookie-target")
            self.send_header("Set-Cookie", "fixture_session=accepted; Path=/")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        elif parsed.path == "/background-cookie-target":
            accepted = "fixture_session=accepted" in self.headers.get("Cookie", "")
            body = b"redirect cookie accepted" if accepted else b"cookie required"
            self.send_response(200 if accepted else 401)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(body)
            return
        elif parsed.path == "/background/reset":
            with Handler.background_lock:
                Handler.background_completed = []
                Handler.background_offline = False
                Handler.background_generation += 1
                Handler.background_denied = 0
            result = {"reset": True}
        elif parsed.path == "/background/offline":
            with Handler.background_lock:
                Handler.background_offline = True
            result = {"offline": True}
        elif parsed.path == "/background/stats":
            with Handler.background_lock:
                result = {"completed": list(Handler.background_completed), "denied": Handler.background_denied}
        elif parsed.path == "/background-source.json":
            with open("Yuedu/Resources/example-source.json", encoding="utf-8") as file:
                template = json.load(file)
            if isinstance(template, list):
                template = template[0]
            result = dict(template, bookSourceName="后台测试书源",
                          bookSourceUrl="http://localhost:8080/background",
                          searchUrl="/background/search?q={{key}}", enabled=True)
        elif parsed.path == "/background/search":
            result = {"books": [{"name": "后台下载手记", "author": "阅读测试",
                                 "url": "/background/book", "intro": "后台持续传输与离线解析测试。"}]}
        elif parsed.path == "/background/book":
            result = {"tocUrl": "/background/toc"}
        elif parsed.path == "/background/toc":
            result = {"chapters": [{"title": f"第{i}章 后台测试",
                                   "url": f"/background/chapter/{i}?g={Handler.background_generation}"}
                                   for i in range(1, 8)]}
        elif parsed.path.startswith("/background/chapter/"):
            background_generation = int(parse_qs(parsed.query).get("g", ["-1"])[0])
            with Handler.background_lock:
                offline = Handler.background_offline
                if offline and background_generation == Handler.background_generation:
                    Handler.background_denied += 1
            if offline:
                self.send_error(503, "Offline test: chapter network disabled")
                return
            background_chapter = int(parsed.path.rsplit("/", 1)[1])
            if background_chapter > 1:
                time.sleep(5)
            result = {"content": f"第{background_chapter}章的正文已由系统下载。\n" +
                      "晨光落在纸上，翻过这一页，故事还在继续。\n" * 30}
        elif parsed.path == "/polish/reset":
            Handler.polish_toc_requests = 0
            result = {"reset": True}
        elif parsed.path == "/polish-sources.json":
            with open("Yuedu/Resources/example-source.json", encoding="utf-8") as file:
                template = json.load(file)
            if isinstance(template, list):
                template = template[0]
            result = [
                dict(template, bookSourceName="打磨测试·原书源",
                     bookSourceUrl="http://localhost:8080/polish-original",
                     searchUrl="/polish/search?q={{key}}", enabled=True),
                dict(template, bookSourceName="打磨测试·备用源",
                     bookSourceUrl="http://localhost:8080/polish-alternative",
                     searchUrl="/polish/search?q={{key}}", enabled=True),
            ]
        elif parsed.path == "/polish/search":
            result = {"books": [{"name": "春日手记", "author": "阅读示例",
                                 "url": "/polish/book", "intro": "目录更新与换源测试。"}]}
        elif parsed.path == "/polish/book":
            result = {"tocUrl": "/polish/toc"}
        elif parsed.path == "/polish/toc":
            Handler.polish_toc_requests += 1
            result = {"chapters": CHAPTERS + (
                [{"title": "第三章 晚风", "url": "/polish/chapter3"}]
                if Handler.polish_toc_requests > 1 else []
            )}
        elif parsed.path == "/polish/chapter3":
            result = {"content": "晚风拂过书页，这是更新目录之后新增的章节。"}
        elif parsed.path == "/search":
            book = {"name": "春日手记", "author": "阅读示例", "url": "/books/1", "intro": "用于验证在线阅读流程的原创测试小书。"}
            result = {"books": [book] if not query or query in "春日手记 阅读示例" else []}
        elif parsed.path == "/books/1":
            result = {"tocUrl": "/books/1/toc"}
        elif parsed.path == "/books/1/toc":
            result = {"chapters": CHAPTERS}
        elif parsed.path in TEXT:
            result = {"content": TEXT[parsed.path]}
        elif parsed.path == "/source.json":
            with open("Yuedu/Resources/example-source.json", encoding="utf-8") as file:
                result = json.load(file)
            if isinstance(result, list):
                for source in result:
                    source["enabled"] = True
            else:
                result["enabled"] = True
        elif parsed.path == "/mixed-sources.json":
            with open("Yuedu/Resources/example-source.json", encoding="utf-8") as file:
                template = json.load(file)
            if isinstance(template, list):
                template = template[0]
            supported = dict(template, bookSourceName="混合测试·规则受支持",
                             bookSourceUrl="http://localhost:8080/mixed-supported", enabled=True)
            scripted = dict(template, bookSourceName="混合测试·脚本书源",
                            bookSourceUrl="http://localhost:8080/mixed-script", enabled=True,
                            bookSourceType=0)
            scripted["ruleContent"] = {"content": "@js:JSON.parse(result).content /* raw_script_marker_should_not_appear */"}
            scripted["customFixtureNote"] = "mixed-import-preserves-metadata"
            scripted["loginUi"] = json.dumps([
                {"name": "测试账号", "type": "text"},
                {"name": "应用设置", "type": "button", "action": "applySettings()"}
            ], ensure_ascii=False)
            scripted["loginUrl"] = "@js:function applySettings(){java.log('设置已应用：'+source.getLoginInfoMap().get('测试账号'));}"
            scripted["exploreUrl"] = json.dumps([{"title": "本地故事", "url": "/search?q=春日"}], ensure_ascii=False)
            scripted["ruleExplore"] = template["ruleSearch"]
            invalid = dict(template, bookSourceUrl="http://localhost:8080/mixed-invalid", enabled=True)
            invalid.pop("bookSourceName", None)
            comic = dict(template, bookSourceName="混合测试·漫画书源",
                         bookSourceUrl="http://localhost:8080/mixed-comic", enabled=True,
                         bookSourceType=2)
            result = [supported, scripted, invalid, comic]
        else:
            self.send_error(404)
            return
        body = json.dumps(result, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
            if background_chapter is not None:
                with Handler.background_lock:
                    if background_generation == Handler.background_generation:
                        Handler.background_completed.append({"chapter": background_chapter, "time": time.time()})
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    print("Test source: http://localhost:8080/source.json", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 8080), Handler).serve_forever()
