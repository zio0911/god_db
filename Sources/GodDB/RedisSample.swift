import AppKit
import GodDBCore
import SwiftUI

/// 개발용: 로컬 Redis 에 샘플 데이터를 넣고 화면을 탭별로 그려 PNG 로 저장
@MainActor
enum RedisSample {
    static func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func render(dir: String, port: Int, password: String, app: AppState) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let profile = ConnectionProfile(kind: .redis, name: "redis-sample", host: "127.0.0.1", port: port,
                                        username: "", database: "5", useTLS: false)
        var done = false
        var ws: RedisWorkspace?
        Task {
            do {
                let s = try await RedisSession.connect(profile: profile, password: password)
                try await s.command(["FLUSHDB"])
                try await s.command(["HSET", "user:1001", "name", "홍길동", "email", "hong@example.com", "grade", "VIP", "point", "1200"])
                try await s.command(["SET", "session:abc", #"{"userId":1001,"roles":["admin","user"],"exp":1767225600}"#, "EX", "3600"])
                try await s.command(["SET", "session:def", "x", "EX", "45"])
                try await s.command(["HSET", "user:1002", "name", "kim"])
                try await s.command(["SET", "user:1001:token", "t", "EX", "86400"])
                try await s.command(["SET", "cache:product:10", "p", "EX", "600"])
                try await s.command(["SET", "cache:product:2", "p", "EX", "7200"])
                try await s.command(["RPUSH", "queue:mail", "m1", "m2", "m3"])
                try await s.command(["SADD", "tags:hot", "redis", "swift", "macos"])
                try await s.command(["ZADD", "rank:weekly", "980", "kim", "1200", "lee", "750", "park"])
                for i in 1...6 {
                    try await s.command(["XADD", "orders", "*", "order_id", "\(5000 + i)", "status", i % 2 == 0 ? "paid" : "new", "amount", "\(i * 12000)"])
                }
                try await s.command(["XGROUP", "CREATE", "orders", "billing", "0"])
                try await s.command(["XREADGROUP", "GROUP", "billing", "worker-1", "COUNT", "3", "STREAMS", "orders", ">"])
                let w = RedisWorkspace(profileID: profile.id, session: s, app: app)
                await w.loadTopology()
                await w.loadDatabases()
                await w.reloadKeys()
                await w.open("user:1001")
                ws = w
            } catch {
                print("ERROR", error)
            }
            done = true
        }
        while !done { spin(0.05) }
        guard let ws else { return }

        func shot(_ name: String, _ view: some View, size: NSSize = NSSize(width: 1100, height: 600)) {
            let host = NSHostingView(rootView: view.environment(app).frame(width: size.width, height: size.height))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            spin(1.2)
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/redis-\(name).png"))
            }
            window.orderOut(nil)
        }

        ws.expanded = Set(RedisSidebarSection.folderIDs(ws.tree))
        shot("sidebar", List { RedisSidebarSection(ws: ws) }.listStyle(.sidebar), size: NSSize(width: 300, height: 520))
        spin(0.5)
        shot("sidebar", List { RedisSidebarSection(ws: ws) }.listStyle(.sidebar), size: NSSize(width: 300, height: 520))
        ws.tab = .keys
        shot("keys-hash", RedisWorkspaceView(ws: ws))
        Task { await ws.open("session:abc") }
        spin(0.5)
        shot("keys-string", RedisWorkspaceView(ws: ws))
        ws.tab = .console
        Task {
            await ws.runConsole("HGETALL user:1001")
            await ws.runConsole("ZRANGE rank:weekly 0 -1 WITHSCORES")
            await ws.runConsole("GET nope")
        }
        spin(0.5)
        shot("console", RedisWorkspaceView(ws: ws))
        ws.tab = .streams
        shot("streams", RedisWorkspaceView(ws: ws), size: NSSize(width: 1100, height: 700))
        ws.tab = .pubsub
        Task {
            await ws.subscribe("news, evt:*")
            try? await Task.sleep(for: .milliseconds(300))
            _ = await ws.publish(channel: "news", message: "배포 완료")
            _ = await ws.publish(channel: "evt:login", message: #"{"user":1001}"#)
        }
        spin(1.0)
        shot("pubsub", RedisWorkspaceView(ws: ws))
        ws.tab = .info
        shot("info", RedisWorkspaceView(ws: ws))
        shot("newkey", RedisNewKeySheet(ws: ws), size: NSSize(width: 600, height: 400))
        ws.tab = .console
        shot("workbench", RedisWorkspaceView(ws: ws))
    }
}
