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
    switch_preview_requests = 0
    cache_counts = {}
    online_retry_requests = 0
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
        elif parsed.path == "/cache/reset":
            Handler.cache_counts = {}
            result = {"reset": True}
        elif parsed.path == "/cache/stats":
            result = {"counts": Handler.cache_counts}
        elif parsed.path == "/cache-source.json":
            with open("Yuedu/Resources/example-source.json", encoding="utf-8") as file:
                template = json.load(file)
            if isinstance(template, list):
                template = template[0]
            result = dict(template, bookSourceName="缓存管理测试源", enabled=True, concurrentRate="100",
                          bookSourceUrl="http://localhost:8080/cache", searchUrl="/cache/search?q={{key}}")
        elif parsed.path == "/cache/search":
            result = {"books": [{"name": "缓存管理手记", "author": "阅读测试", "url": "/cache/book", "intro": "章节清理与下载任务测试。"}]}
        elif parsed.path == "/cache/book":
            result = {"tocUrl": "/cache/toc"}
        elif parsed.path == "/cache/toc":
            result = {"chapters": [{"title": f"第{i}章 缓存测试", "url": f"/cache/chapter/{i}"} for i in range(1, 6)]}
        elif parsed.path.startswith("/cache/chapter/"):
            index = parsed.path.rsplit("/", 1)[-1]
            Handler.cache_counts[index] = Handler.cache_counts.get(index, 0) + 1
            attempt = Handler.cache_counts[index]
            if index == "2":
                time.sleep(4)
            result = {"content": "" if index == "3" and attempt == 1 else f"第{index}章缓存管理正文。\n" + "晨光落在书页上，故事还在继续。\n" * 45}
        elif parsed.path == "/switch/reset":
            Handler.switch_preview_requests = 0
            result = {"reset": True}
        elif parsed.path == "/switch-sources.json":
            with open("Yuedu/Resources/example-source.json", encoding="utf-8") as file:
                template = json.load(file)
            if isinstance(template, list):
                template = template[0]
            result = [dict(template, bookSourceName=name, enabled=True,
                           bookSourceUrl=f"http://localhost:8080/switch/{edition}",
                           searchUrl=f"/switch/{edition}/search?q={{{{key}}}}")
                      for edition, name in [("original", "换源测试·原源"),
                                            ("alternate", "换源测试·备用"),
                                            ("unrelated", "换源测试·同名异书")]]
        elif parsed.path.startswith("/switch/"):
            _, _, edition, action, *rest = parsed.path.split("/")
            if action == "search":
                result = {"books": [{"name": "换源测试小说", "author": "不同作者" if edition == "unrelated" else "阅读测试",
                                     "url": f"/switch/{edition}/book", "intro": "换源与试读验证。"}]}
            elif action == "book":
                result = {"tocUrl": f"/switch/{edition}/toc"}
            elif action == "toc":
                titles = ["第一章 初见", "第二章 重逢"] if edition == "original" else (
                    ["序章", "第1章：初见", "第2章：重逢"] if edition == "alternate" else ["第一章 不同故事"])
                result = {"chapters": [{"title": title, "url": f"/switch/{edition}/chapter/{index}"}
                                       for index, title in enumerate(titles)]}
            elif action == "chapter":
                index = int(rest[0])
                if edition == "original" and index == 1:
                    result = {"content": ""}
                elif edition == "alternate" and index == 2:
                    Handler.switch_preview_requests += 1
                    if Handler.switch_preview_requests == 2:
                        time.sleep(4)
                    result = {"content": "" if Handler.switch_preview_requests == 1 else "备用版本重逢正文。\n" + "重逢后，故事继续。\n" * 40}
                else:
                    result = {"content": ("原版本初见正文。" if edition == "original" else "此版本的试读正文。") + "\n风从书页间吹过。" * 40}
            else:
                result = {"error": "Unknown switch fixture action"}
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
        elif parsed.path == "/discovery-sources.json":
            with open("Yuedu/Resources/example-source.json", encoding="utf-8") as file:
                template = json.load(file)
            if isinstance(template, list):
                template = template[0]
            base = "http://" + self.headers.get("Host", "localhost:8080")
            def source(name, suffix, group, explore, **extra):
                return dict(template, bookSourceName=name, bookSourceUrl=base + suffix,
                            enabled=True, bookSourceGroup=group, exploreUrl=explore,
                            ruleExplore=template["ruleSearch"], **extra)
            result = [
                source("本地发现·分类", "/discover-main", "小说,测试", json.dumps([
                    {"title": "榜单", "url": ""},
                    {"title": "热门榜单", "url": "/discovery/list?page={{page}}"},
                    {"title": "新书", "url": "/discovery/list?page={{page}}"},
                    {"title": "完本", "url": "/discovery/list?page={{page}}"},
                    {"title": "分类", "url": ""},
                    {"title": "玄幻", "url": "/discovery/list?page={{page}}"},
                    {"title": "都市", "url": "/discovery/list?page={{page}}"},
                ], ensure_ascii=False)),
                source("本地发现·动态", "/discover-script", "文学", "@js:JSON.stringify([{title:'本地故事',url:'/discovery/list?page={{page}}'}])"),
                source("本地发现·故障", "/discover-error", "测试", "@js:throw new Error('测试分类故障')"),
                source("仅搜索书源", "/discover-search", "测试", ""),
                source("已关闭发现", "/discover-hidden", "测试", "隐藏::/search", enabledExplore=False),
            ]
        elif parsed.path == "/discovery/list":
            page = int(parse_qs(parsed.query).get("page", ["1"])[0])
            result = {"books": ([{"name": "春日手记" if page == 1 else "夏夜手记",
                                 "author": "阅读示例", "url": "/books/1" if page == 1 else "/books/2",
                                 "intro": "发现分类与分页测试书籍。"}] if page in [1, 2] else [])}
        elif parsed.path in ["/books/2", "/books/3"]:
            result = {"tocUrl": "/books/1/toc"}
        elif parsed.path == "/purification-source.json":
            with open("Yuedu/Resources/example-source.json", encoding="utf-8") as file:
                template = json.load(file)
            if isinstance(template, list):
                template = template[0]
            result = dict(template, bookSourceName="净化测试书源", enabled=True,
                          bookSourceUrl="http://localhost:8080/purification",
                          searchUrl="/purification/search?q={{key}}")
        elif parsed.path == "/purification/search":
            result = {"books": [{"name": "净化测试手记", "author": "阅读测试", "url": "/purification/book", "intro": "原文缓存与净化测试。"}]}
        elif parsed.path == "/purification/book":
            result = {"tocUrl": "/purification/toc"}
        elif parsed.path == "/purification/toc":
            result = {"chapters": [{"title": "第一章 初见", "url": "/purification/chapter/1"},
                                   {"title": "第二章 重逢", "url": "/purification/chapter/2"}]}
        elif parsed.path.startswith("/purification/chapter/"):
            number = parsed.path.rsplit("/", 1)[1]
            title = "第一章 初见" if number == "1" else "第二章 重逢"
            result = {"content": title + "\n\n推广：净化测试广告\n\n" +
                      "正文应始终保留，窗边的风轻轻吹过。\n\n" * 40}
        elif parsed.path == "/online-sources.json":
            Handler.online_retry_requests = 0
            with open("Yuedu/Resources/example-source.json", encoding="utf-8") as file:
                template = json.load(file)
            if isinstance(template, list):
                template = template[0]
            result = [dict(template, bookSourceName=name,
                           bookSourceUrl=f"http://localhost:8080/online-{kind}",
                           bookSourceGroup=group, enabled=True,
                           searchUrl=f"/online/search/{kind}?q={{{{key}}}}&page={{{{page}}}}")
                      for name, kind, group in [("搜索测试·一号", "first", "常用"),
                                                ("搜索测试·二号", "second", "常用"),
                                                ("搜索测试·重试", "retry", "备用")]]
        elif parsed.path.startswith("/online/search/"):
            kind = parsed.path.rsplit("/", 1)[1]
            page = int(parse_qs(parsed.query).get("page", ["1"])[0])
            if kind == "retry":
                Handler.online_retry_requests += 1
                if Handler.online_retry_requests == 1:
                    self.send_error(503, "Temporary search failure: retry this source")
                    return
            exact = {"name": "春日手记", "author": "阅读示例", "url": "/books/1", "intro": "跨源同书与搜索分页测试。"}
            author = {"name": "远山故事", "author": "春日手记", "url": "/books/2", "intro": "按作者筛选的测试作品。"}
            more = {"name": "夏夜手记", "author": "阅读示例", "url": "/books/3", "intro": "第二页新增结果。"}
            recovered = {"name": "冬日手记", "author": "阅读示例", "url": "/books/1", "intro": "重试失败书源后返回的结果。"}
            if kind == "first":
                books = [exact, exact, author] if page == 1 else ([exact, more] if page == 2 else [])
            elif kind == "second":
                books = [exact]  # Intentionally ignores page; the app must stop repeated pages.
            else:
                books = [recovered]
            result = {"books": books}
        elif parsed.path == "/source-tools.json":
            with open("Yuedu/Resources/example-source.json", encoding="utf-8") as file:
                template = json.load(file)
            if isinstance(template, list):
                template = template[0]
            result = [
                dict(template, bookSourceName="工具测试·正常", bookSourceUrl="http://localhost:8080/tools-good", enabled=False, bookSourceGroup="网文", exploreUrl="热门::/search", ruleExplore=template["ruleSearch"]),
                dict(template, bookSourceName="工具测试·故障", bookSourceUrl="http://localhost:8080/tools-fail", enabled=True, bookSourceGroup="网文", searchUrl="/missing-tools-endpoint?q={{key}}"),
                dict(template, bookSourceName="工具测试·空结果", bookSourceUrl="http://localhost:8080/tools-empty", enabled=True, bookSourceGroup="备用", searchUrl="/search?q=no-matching-book"),
            ]
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
