import Foundation
import Testing
@testable import GodDBCore

@Suite("DBeaver import")
struct DBeaverImportTests {
    /// DBeaver 26.2 에서 파일 > 내보내기 > DBeaver > 프로젝트 로 만든 .dbp (Docker 테스트 DB 접속).
    /// 폴더 Docker Test / Docker Test/Bastion, MySQL(읽기전용) · PostgreSQL · SQL Server(SSH 공개키), 샘플 SQLite.
    /// credentials-config.json 에는 사용자 이름만 있다 (비밀번호 없음). meta.xml 의 주소 · 호스트 이름은 바꿔 둠.
    static let dbp = Data(base64Encoded: """
    UEsDBBQAAAAIAIlld11kR9wlCgEAAEcCAAAIAAAAbWV0YS54bWyFkttOwzAMhl8lyn3dFrEVpLaTEIIHAB4gOF6XqU1KHCYen/TE
    JspBubHsz7//OCl3H10rTuTZOFvJHDIpyKLTxjaVfHl+SG7kri6Vx4M50QUo65Ldu0cSwXQUE8Xt5jrbZNtimxdSKK09Mcf8VQFZ
    PLkUB8ehkoE4JJ1CaB2qVqZ12Xt3JAz8FQmrBslHsuQjIjQxetOHcfKcFfd3pKIdMfdEP3Hg5GhqB/06EusKetJkg1EtJ+js3jRw
    ZGcHL99IrYJKpgz/xswGko6CGvj/OKYQ4nbPeukCrlpgYdd3cL4Bwtb0TIDOEyx1ht7Tnv8Wfhr3+YPsVAB+G1/mQiCd7Z+j+F7p
    /C/qT1BLAwQKAAAAAACJZXddAAAAAAAAAAAAAAAACQAAAHByb2plY3RzL1BLAwQKAAAAAACJZXddAAAAAAAAAAAAAAAAEQAAAHBy
    b2plY3RzL0dlbmVyYWwvUEsDBAoAAAAAAIlld10AAAAAAAAAAAAAAAAaAAAAcHJvamVjdHMvR2VuZXJhbC8uZGJlYXZlci9QSwME
    FAAAAAgAiWV3XQZbO4BkAAAAfAAAAC8AAABwcm9qZWN0cy9HZW5lcmFsLy5kYmVhdmVyL3Byb2plY3QtbWV0YWRhdGEuanNvbj3M
    SwqEMBCE4bv02ihuvYDM2hO0SQkZMpPY3c5GcndfMKuC+uDfSaB5Ew+lYafJSyym3bOtrul6Axbekrki+Q1vr0ADjfhCOFHz18DG
    T+rkMIN/EKf8KQm3zaxwZzEaXE+11gNQSwMECgAAAAAAiWV3Xbu+XAkgAQAAIAEAADEAAABwcm9qZWN0cy9HZW5lcmFsLy5kYmVh
    dmVyL2NyZWRlbnRpYWxzLWNvbmZpZy5qc29u86nTNF99p8PpjJYtEIEopcBKDzMw6xzMtobtsrD9CjwweuvXBA8+rB9zDQGK2NQz
    hXJdbR2/ja++P13mu9qRlnvFqKjzrewhcxkZ60RQFXN63seioyFmazQGT7JBTuEZKAFb4SE0arwDmxxpdnbPVyNO17C65KbR+rOJ
    YOWxi+yIGDuYbRs3Q1wN7rH4TN18alxXlunzodD2sgDl4Hwt5Xi1aHOz79DXZKiJqIxVoUjw00eKRQ7Bmb6M5YrRZrKugIYFoG4G
    QOgvSt0jt1cwuKYPj974iHmiLm5EG7mxe2SECO/cnpHXmh45odA9WpxZWvuBU1mDlyfgOxddkN8OAG3euoxrG7fnJ+YdtNoBKxvf
    wF9Q6yZNRe67ql253cwFUEsDBAoAAAAAAIlld108IpyrLQAAAC0AAAAvAAAAcHJvamVjdHMvR2VuZXJhbC8uZGJlYXZlci9wcm9q
    ZWN0LXNldHRpbmdzLmpzb257ImlkIjoiMjg0NmNmMzEtMTJhNS00MmI0LWFlOGItOGVjOGVhNTAxNGY0In1QSwMEFAAAAAgAiWV3
    XdS90ScHBAAAVAwAACsAAABwcm9qZWN0cy9HZW5lcmFsLy5kYmVhdmVyL2RhdGEtc291cmNlcy5qc29uvVbbbttGEH2Wv0LgUwtk
    RZG6WfZLYjtoitiGE9kPRVsIS+7Iok1y2d2lEiFIv70zy7tMNzAKV4IumJk9czlnl/vtaOBsZCxAaedk+O1oMHAuZPgIangL2pDp
    +5sDo3vGtYlkap1HA/I7oUxTCMlaw4gA+A4U0zzJYmCCGx5wDUz/FUcGmFfGDZxMyV2EBaDBKZwOpUQEFe3a5vWDCMLSl/IEyHNx
    ZrMMVzbL8KLMMvxp9ekSl/xchmsMYhnX+otUAtcZlUPp2covTO+1gYTJ4AGboA4aP3a2ie5zxauWyYq1lYmoBvdO4/hcg7MB5V5G
    geJq75aVUUUuZn3UGQ9h7o4SMJxWu88Nxj3fRqmUjyMRFNUPnFzFlIj6PynCTl4/aafz231me716d3337rIKMaVVwM4hC8rB6mHg
    JHtEPmYe98fzxWy+nByzWbgc+96Ucz/wJwLmvQKw657wX6AdUP+LFBdnw6s9Mv1DlhVwwWQa7zvWQvhWRi3N/yvvW2l3heP5i9EY
    3141ikwq65hMJuN5ZWyrBIWW9fFpeztx3RrxxEK47fgXUlGVVM6V4Z8MlImg2pzkfVtvUNoBPI6ZCPRbgqABWToLLjGW52bLEinA
    lp1iGbsioiE8w8HcK9CMmip5nwt/OWULfxnCeC4Wwttgk35VQ4f3ankP+R3kXg3cFBGNEF6F2Nl04r+E2KalLruE8z+zm8qUCdjw
    PDbIsiV5w2P9cpaTKFRSy40pGV6Gk+MZwx+xmYEXzP1jmHuLXoZxDnhiEaeHBNegveRerZBXtlp9KL3Pb/Je1uun1X9k35tOJn3s
    J5wO4D7+64aR/tPi3zV29kc+Hk9EneiUMhQ2m+O0Am9iuyleXy10FuhwC5i3JZUCCOev41uVa7OyHZ0T1iYKubEZf6iqeijreohl
    3JanIm6uIUWq7drkeLOgpaWx6e727vr6fdUz2iHlQQwdSViQ5/RCzr5poPkhT7Kiv1Eo85QUMK7WNGIJCmWN4Kt9qI7oWVyXU0vH
    x1djpGlUpN3cnV3+er7++P631qpH2N9wsyX/3+4IJ+DeSyGCNYGvQfizmbdshUeUOYHUVIKmoT20AvSWK7i1Q+xcbKwzliGPP5Tt
    tBYpSKSB2lHa6Riof+y3PRieXAEZMdTcA1GE1XlQ39pgB7HMqO56X8bSbl1s8E35absuuHrsdwvQoYqyqv3PcJ/HXA1Fk2LYlRpx
    IFkokySi9g6ueiph8BXC3OrZyrnrJCwWoljvDwJ0wpVpYJ/xMAWhLM69JnFRUCzxPmYUTzWvb9Kt4p64GSo3kiRp73hcyLON1L2S
    HwK1vC2c6bQC0jgCFRm6L5VHJEYlkdbELz7UjIpq7N//pIhKC0ff/wFQSwMECgAAAAAAiWV3XQAAAAAAAAAAAAAAABsAAABwcm9q
    ZWN0cy9HZW5lcmFsLy5zZXR0aW5ncy9QSwMECgAAAAAAiWV3XQ3o3k03AAAANwAAADsAAABwcm9qZWN0cy9HZW5lcmFsLy5zZXR0
    aW5ncy9vcmcuZWNsaXBzZS5jb3JlLnJlc291cmNlcy5wcmVmc2VjbGlwc2UucHJlZmVyZW5jZXMudmVyc2lvbj0xCmVuY29kaW5n
    Lzxwcm9qZWN0Pj1VVEYtOApQSwMECgAAAAAAiWV3XQAAAAAAAAAAAAAAABkAAABwcm9qZWN0cy9HZW5lcmFsL1NjcmlwdHMvUEsD
    BAoAAAAAAIlld10AAAAAAAAAAAAAAAAjAAAAcHJvamVjdHMvR2VuZXJhbC9TY3JpcHRzL1NjcmlwdC5zcWxQSwECHgMUAAAACACJ
    ZXddZEfcJQoBAABHAgAACAAAAAAAAAABAAAApIEAAAAAbWV0YS54bWxQSwECHgMKAAAAAACJZXddAAAAAAAAAAAAAAAACQAAAAAA
    AAAAABAA7UEwAQAAcHJvamVjdHMvUEsBAh4DCgAAAAAAiWV3XQAAAAAAAAAAAAAAABEAAAAAAAAAAAAQAO1BVwEAAHByb2plY3Rz
    L0dlbmVyYWwvUEsBAh4DCgAAAAAAiWV3XQAAAAAAAAAAAAAAABoAAAAAAAAAAAAQAO1BhgEAAHByb2plY3RzL0dlbmVyYWwvLmRi
    ZWF2ZXIvUEsBAh4DFAAAAAgAiWV3XQZbO4BkAAAAfAAAAC8AAAAAAAAAAQAAAKSBvgEAAHByb2plY3RzL0dlbmVyYWwvLmRiZWF2
    ZXIvcHJvamVjdC1tZXRhZGF0YS5qc29uUEsBAh4DCgAAAAAAiWV3Xbu+XAkgAQAAIAEAADEAAAAAAAAAAAAAAKSBbwIAAHByb2pl
    Y3RzL0dlbmVyYWwvLmRiZWF2ZXIvY3JlZGVudGlhbHMtY29uZmlnLmpzb25QSwECHgMKAAAAAACJZXddPCKcqy0AAAAtAAAALwAA
    AAAAAAABAAAApIHeAwAAcHJvamVjdHMvR2VuZXJhbC8uZGJlYXZlci9wcm9qZWN0LXNldHRpbmdzLmpzb25QSwECHgMUAAAACACJ
    ZXdd1L3RJwcEAABUDAAAKwAAAAAAAAABAAAApIFYBAAAcHJvamVjdHMvR2VuZXJhbC8uZGJlYXZlci9kYXRhLXNvdXJjZXMuanNv
    blBLAQIeAwoAAAAAAIlld10AAAAAAAAAAAAAAAAbAAAAAAAAAAAAEADtQagIAABwcm9qZWN0cy9HZW5lcmFsLy5zZXR0aW5ncy9Q
    SwECHgMKAAAAAACJZXddDejeTTcAAAA3AAAAOwAAAAAAAAABAAAApIHhCAAAcHJvamVjdHMvR2VuZXJhbC8uc2V0dGluZ3Mvb3Jn
    LmVjbGlwc2UuY29yZS5yZXNvdXJjZXMucHJlZnNQSwECHgMKAAAAAACJZXddAAAAAAAAAAAAAAAAGQAAAAAAAAAAABAA7UFxCQAA
    cHJvamVjdHMvR2VuZXJhbC9TY3JpcHRzL1BLAQIeAwoAAAAAAIlld10AAAAAAAAAAAAAAAAjAAAAAAAAAAAAAACkgagJAABwcm9q
    ZWN0cy9HZW5lcmFsL1NjcmlwdHMvU2NyaXB0LnNxbFBLBQYAAAAADAAMALADAADpCQAAAAA=
    """, options: .ignoreUnknownCharacters)!

    func profile(_ r: DBeaverImport.Result, _ name: String) -> ConnectionProfile? {
        r.sources.first { $0.profile.name == name }?.profile
    }

    @Test func readsExportedProject() throws {
        let r = try DBeaverImport.parse(Self.dbp)
        #expect(r.sources.count == 3)
        #expect(r.skipped == ["DBeaver Sample Database (SQLite)"])

        let my = try #require(profile(r, "GodDB MySQL"))
        #expect(my.kind == .mysql)
        #expect(my.host == "127.0.0.1" && my.port == 33306)
        #expect(my.database == "shop")
        #expect(my.username == "root")
        #expect(my.readOnly)
        #expect(my.group == "Docker Test")
        #expect(my.ssh == nil)
        #expect(!my.useTLS)

        let pg = try #require(profile(r, "GodDB PostgreSQL"))
        #expect(pg.kind == .postgres)
        #expect(pg.host == "127.0.0.1" && pg.port == 35432)
        #expect(pg.database == "shop")
        #expect(pg.username == "postgres")
        #expect(!pg.readOnly)
        #expect(pg.group == "Docker Test")

        let ms = try #require(profile(r, "GodDB MSSQL-SSH"))
        #expect(ms.kind == .mssql)
        #expect(ms.host == "127.0.0.1" && ms.port == 31433)
        #expect(ms.database == "master")
        #expect(ms.username == "sa")
        #expect(ms.group == "Docker Test/Bastion")
        let ssh = try #require(ms.ssh)
        #expect(ssh.host == "bastion.example.test" && ssh.port == 2222)
        #expect(ssh.username == "tunnel")
        #expect(ssh.keyPath == "~/.ssh/goddb_test_ed25519")
    }

    @Test func notesAskForPasswordOnly() throws {
        let r = try DBeaverImport.parse(Self.dbp)
        for s in r.sources {
            #expect(s.notes == [tr("비밀번호는 처음 연결할 때 입력해요.")], "\(s.profile.name): \(s.notes)")
        }
    }

    @Test func sameDBeaverConnectionKeepsID() throws {
        let a = try DBeaverImport.parse(Self.dbp)
        let b = try DBeaverImport.parse(Self.dbp)
        #expect(a.sources.map(\.profile.id) == b.sources.map(\.profile.id))
        #expect(Set(a.sources.map(\.profile.id)).count == 3)
        // 다시 가져오면 덮어쓰기로 인식
        let existing = a.sources.map(\.profile)
        #expect(ConnectionTransfer.action(for: b.sources[0].profile, existing: existing) != .add)
    }

    @Test func readsDataSourcesJSONWithSiblingCredentials() throws {
        let files = try ZipReader.read(Self.dbp) { $0.contains("/.dbeaver/") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dbeaver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["data-sources.json", "credentials-config.json"] {
            try #require(files["projects/General/.dbeaver/\(name)"]).write(to: dir.appendingPathComponent(name))
        }
        let r = try DBeaverImport.parse(fileAt: dir.appendingPathComponent("data-sources.json"))
        #expect(r.sources.count == 3)
        #expect(profile(r, "GodDB MSSQL-SSH")?.ssh?.username == "tunnel")

        // 비밀번호 파일이 없으면 사용자 이름 없이 가져오고 알려준다
        try FileManager.default.removeItem(at: dir.appendingPathComponent("credentials-config.json"))
        let r2 = try DBeaverImport.parse(fileAt: dir.appendingPathComponent("data-sources.json"))
        let my = try #require(r2.sources.first { $0.profile.name == "GodDB MySQL" })
        #expect(my.profile.username.isEmpty)
        #expect(my.notes.contains(tr("사용자 이름이 없어요. 접속 편집에서 넣어 주세요.")))
        #expect(r2.sources.first { $0.profile.name == "GodDB MSSQL-SSH" }?.notes.contains(tr("SSH 사용자 이름이 없어요. 접속 편집에서 넣어 주세요.")) == true)
    }

    @Test func credentialsGiveOnlyUserNames() {
        let files = try? ZipReader.read(Self.dbp) { $0.hasSuffix("credentials-config.json") }
        let users = DBeaverImport.users(inCredentials: files?.values.first ?? Data())
        #expect(users["microsoft-1a20679c385-79cdf5e1b628e617"] == .init(database: "sa", ssh: "tunnel"))
        #expect(users.count == 3)
        // 깨진 파일은 빈 결과
        #expect(DBeaverImport.users(inCredentials: Data(repeating: 7, count: 48)).isEmpty)
    }

    // 손으로 만든 data-sources.json (옛 폴더 형식, URL 방식, SSH 비밀번호 방식, SSL)
    let handMade = """
    {
      "folders": { "운영": {}, "주문": { "parent": "운영" } },
      "connections": {
        "pg-url-1": { "provider": "postgresql", "driver": "postgres-jdbc", "name": "주문 DB", "folder": "주문",
          "configuration": { "url": "jdbc:postgresql://db.example.test:6543/orders", "configurationType": "URL", "user": "app",
            "handlers": {
              "postgre_ssl": { "type": "CONFIG", "enabled": true, "properties": { "sslMode": "require" } },
              "ssh_tunnel": { "type": "TUNNEL", "enabled": true,
                "properties": { "host": "jump.example.test", "port": "22", "authType": "PASSWORD", "jumpServer.count": 1 } } } } },
        "maria-1": { "provider": "mysql", "driver": "mariaDB", "name": "마리아",
          "configuration": { "host": "maria.example.test", "port": 3307, "database": "app",
            "handlers": { "ssh_tunnel": { "type": "TUNNEL", "enabled": false, "properties": { "host": "x" } } } } },
        "oracle-1": { "provider": "oracle", "driver": "oracle_thin", "name": "오라클", "configuration": { "host": "o.example.test" } }
      }
    }
    """

    @Test func handMadeDataSources() throws {
        let r = try DBeaverImport.parse(Data(handMade.utf8))
        #expect(r.skipped == ["오라클"])
        let pg = try #require(r.sources.first { $0.profile.name == "주문 DB" })
        #expect(pg.profile.group == "운영/주문")
        #expect(pg.profile.host == "db.example.test" && pg.profile.port == 6543)
        #expect(pg.profile.database == "orders")
        #expect(pg.profile.username == "app")
        #expect(pg.profile.useTLS && !pg.profile.tlsVerify)
        #expect(pg.profile.ssh?.host == "jump.example.test")
        #expect(pg.profile.ssh?.keyPath == "")
        #expect(pg.notes.contains(tr("SSH 비밀번호 방식이에요. GodDB 는 키 파일이나 ssh-agent 로 연결하니 접속 편집에서 키를 지정해 주세요.")))
        #expect(pg.notes.contains(tr("SSH 점프 서버 설정은 가져오지 않았어요.")))

        let maria = try #require(r.sources.first { $0.profile.name == "마리아" })
        #expect(maria.profile.kind == .mysql && maria.profile.port == 3307)
        #expect(maria.profile.ssh == nil)
        #expect(maria.profile.group.isEmpty)
    }

    @Test func errors() {
        #expect(throws: DBeaverImport.ParseError.notDBeaver) { try DBeaverImport.parse(Data("{\"format\":\"goddb-connections\"}".utf8)) }
        #expect(throws: DBeaverImport.ParseError.noConnections) { try DBeaverImport.parse(Data("{\"connections\":{}}".utf8)) }
        let onlySQLite = #"{"connections":{"s":{"provider":"sqlite","name":"로컬","configuration":{"database":"/tmp/a.db"}}}}"#
        #expect(throws: DBeaverImport.ParseError.nothingSupported(["로컬"])) { try DBeaverImport.parse(Data(onlySQLite.utf8)) }
        #expect(!DBeaverImport.looksLikeDBeaver(Data("{\"format\":\"goddb-connections\",\"profiles\":[]}".utf8)))
        #expect(DBeaverImport.looksLikeDBeaver(Self.dbp))
    }
}
