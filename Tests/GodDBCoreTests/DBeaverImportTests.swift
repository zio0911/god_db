import Foundation
import Testing
@testable import GodDBCore

@Suite("DBeaver import")
struct DBeaverImportTests {
    /// DBeaver 26.2 에서 파일 > 내보내기 > DBeaver > 프로젝트 로 만든 .dbp (Docker 테스트 DB 접속).
    /// 폴더 Docker Test / Docker Test/Bastion, MySQL(읽기전용) · PostgreSQL · SQL Server(SSH 공개키),
    /// Redshift(가짜 호스트, 연결 안 됨 — 형식 확인용), 샘플 SQLite.
    /// credentials-config.json 에는 사용자 이름만 있다 (비밀번호 없음). meta.xml 의 주소 · 호스트 이름은 바꿔 둠.
    static let dbp = Data(base64Encoded: """
    UEsDBBQAAgAIADd2d11CSqiaCgEAAEcCAAAIAAAAbWV0YS54bWyFkt1OwzAMhV8lyn3TtdoYk9pOQggeAHiA4HhdpjQpcZh4fNI2
    ZWjlR7mx7C/Hx06q/Udn2Bk9aWdrXogVZ2jBKW3bmr88P2S3fN9U0sNRn/EbyJuK3LsHZEF3GBPb3WZdlLubdVlsOJNKeSSK+XIr
    VvEUnB0dhZoHpJB1EoRxIA3Pm6r37oQQ6CtiVg6Sj2jRR4QpJPC6D2PnlGX3dyijHZbuRD+x4eRoui7U60gsK+BRoQ1aGsrA2YNu
    xYmcHbxckUoGmU0Z+o1JBrIOgxz4/zjCEOJ2L3r5DC5HmNnlDM63AsHonlCA8yjmOone44H+Fn4a9/mD7FQQ9GauBPJk/xLF98rT
    v2g+AVBLAwQKAAAAAAA3dnddAAAAAAAAAAAAAAAACQAAAHByb2plY3RzL1BLAwQKAAAAAAA3dnddAAAAAAAAAAAAAAAAEQAAAHBy
    b2plY3RzL0dlbmVyYWwvUEsDBAoAAAAAADd2d10AAAAAAAAAAAAAAAAaAAAAcHJvamVjdHMvR2VuZXJhbC8uZGJlYXZlci9QSwME
    FAACAAgAN3Z3XQZbO4BkAAAAfAAAAC8AAABwcm9qZWN0cy9HZW5lcmFsLy5kYmVhdmVyL3Byb2plY3QtbWV0YWRhdGEuanNvbj3M
    SwqEMBCE4bv02ihuvYDM2hO0SQkZMpPY3c5GcndfMKuC+uDfSaB5Ew+lYafJSyym3bOtrul6Axbekrki+Q1vr0ADjfhCOFHz18DG
    T+rkMIN/EKf8KQm3zaxwZzEaXE+11gNQSwMECgACAAAAN3Z3XeG1WqJwAQAAcAEAADEAAABwcm9qZWN0cy9HZW5lcmFsLy5kYmVh
    dmVyL2NyZWRlbnRpYWxzLWNvbmZpZy5qc29umIKQspFyAOE21Jfq5ikUcfpuHcaW1b43LVroYbHfrvfri/J/XIvcN46rQ8gH+O3B
    x3PEso6Dw+dYx4I/tyYpGSxHcvAZmxSr0PBrymI8M3DkD2ywanpCRM8uJtRiazqITJZhpWvH+T3ZWG9PunfQk+5lYtReG8qBwBLj
    uxhXT2luzEd/Der5q5Vc3mLF3YSnD+rCbc+X923y3gLohoHU7IUkksQaBJzVItx95YdvEDdMHp56zpngbBqWMSdMKSk3j/ShJAr9
    LjBDcY7x1ExA8jQ25eNSz7GmNidwUupLaAM9aXnpajVMzske3bAaUJ1U154odGBsXRIowXDZbmHLo1mUd/aTC/8uva5pbCtThqbq
    l2fn4d0J3psaCKCZLnHn2i9NXa+1a0TUK6Bcata49REcmf8TtAkGzVL/oP70Dy9zkCVXBf523gzN+f1qHt15YjuOWYaacmZGdSIc
    9pD+vqWoNFcsJr4JACsBEfBUSLZQSwMECgACAAAAN3Z3XTwinKstAAAALQAAAC8AAABwcm9qZWN0cy9HZW5lcmFsLy5kYmVhdmVy
    L3Byb2plY3Qtc2V0dGluZ3MuanNvbnsiaWQiOiIyODQ2Y2YzMS0xMmE1LTQyYjQtYWU4Yi04ZWM4ZWE1MDE0ZjQifVBLAwQUAAIA
    CAA3dnddeWwCE2cEAADIDgAAKwAAAHByb2plY3RzL0dlbmVyYWwvLmRiZWF2ZXIvZGF0YS1zb3VyY2VzLmpzb27VV21P20gQ/hx+
    ReRPdxJrx3ZiSPjSAtX1VIpoAx9Od6do7Z1gg+317a5DcxX32zvrdyemLa1a6UAoaGZ23p5nZrMfD0bGmscMhDQW448Ho5FxzoN7
    EONrkEqLHg93hNYplSriaaE8GGm9EfA0hUBLGzfMB7oBQSRNshgIo4r6VAKR/8SRAmJXdiMjE3wTYQIoMEqlcVgomIg2XfHqjvlB
    pUtpAlpzflpEGS+LKOPzKsr4l+W7Czzya2Uu0YhkVMoHLhieUyKHShPyByK3UkFCuH+HRcieHitbR7e5oHXJWoq5VYF0DtaNxPZZ
    CnsDwrqIfEHF1qoy0xlZGPVeZjQAzzITUFSftp5qjHUWRinn9ybzy+xHRi5iHUjXvyjNFj8+aK/y621W1Pr25eXNy4vaRFVSBhtD
    S5AOo5IvyRY9HxObOhPvaObN3WMyC+YTx55S6viOy8AbJEBxbg//0tsO9L9xdn46frtFpL+IsgDKCE/jbU9aEr+gUYfzn8U95MVU
    GLZzZE7w165bkXFRKFzXnXi1sMsSJFo2hGdR28KyGo+LwoXVtX8mFHVKVV8J/pOBUBHIppCR8aIZUD0BNI4J8+UL7UI3qICzxBJt
    aa5CknAGRdopprGBHcAzbMytAEl0URXuHnPmU3LkzAOYeOyI2Wss0hnEvT4+AH7P8yAHrkqLlgg/BNjZ1HWeA2xbUh9d7ecno5vy
    lDBY0zxWiHIB8prG8vkoJ1EguORrVSE8D9zjGcEPtp6B7XvOMXj20VOrHTeWxnRvumunwwO+RFzJcvn6i0M+iHpzW30n+vbUdYfQ
    T6hewE8s6rJghP+k/O8SK/srn0xc1gQ60RFKWRHjpHbe2vZD/JxdIIMQMG6HKoeVrZTxtcilWhYVnWlf6yigCr6KVU1TVk0TK7uQ
    pixuv4aUocKVyvGbRdwK2+quby4vX9U1oxxS6sfQo8Rn+VK1Za8bKL7Lk6yszwx4nmoGIFiHjb6mi19yy4QPxbVqqmbNdMnj4E/3
    tO5IDdzVzenF72erN6/+6Jy7h+0VVaHW/2eZ2AXrljPmr7T7FTBnNrPnHfNIx04gVTWpdePuOgYypAKui0bKnQ6MjJgHNH5dFdQ5
    JCDhChpFJX886Hw8PnEFCGAyjHBJtHfB2mG4K8jUtz1vMoP52p7pLwPffBf0QgzujfeVxbetja9bFxXuJIhzPaIm9QPbcU2a4cYV
    KgSkB3HMOleTJvRfntIHiaxKdjcMXgvzoQXTGeLudqmd4nL5niwWOqzVifH/uIz2nh1EJ9W+PTCzmlnNSwE2EPNMz0kDbswL3HGg
    Dqu/ruqcivthNQMZiCirx+093OYxFWPWhhj315suhxPsdxKp/eeFSAh8gCAvdmjRi75S+yIBLsjbHQOZUKFat09ocFgCXg5QG7hM
    KOb4BlCCppI2r7dOcntqguBGXM+PfTyZ7HnqPwN3HXW0HT/Tae1IYgtEpLbtnKFVEkmp8cWhVyJqfP/5d5cLB4+fAFBLAwQKAAAA
    AAA3dnddAAAAAAAAAAAAAAAAGwAAAHByb2plY3RzL0dlbmVyYWwvLnNldHRpbmdzL1BLAwQKAAIAAAA3dnddDejeTTcAAAA3AAAA
    OwAAAHByb2plY3RzL0dlbmVyYWwvLnNldHRpbmdzL29yZy5lY2xpcHNlLmNvcmUucmVzb3VyY2VzLnByZWZzZWNsaXBzZS5wcmVm
    ZXJlbmNlcy52ZXJzaW9uPTEKZW5jb2RpbmcvPHByb2plY3Q+PVVURi04ClBLAwQKAAAAAAA3dnddAAAAAAAAAAAAAAAAGQAAAHBy
    b2plY3RzL0dlbmVyYWwvU2NyaXB0cy9QSwMECgAAAAAAN3Z3XQAAAAAAAAAAAAAAACMAAABwcm9qZWN0cy9HZW5lcmFsL1Njcmlw
    dHMvU2NyaXB0LnNxbFBLAQIeAxQAAgAIADd2d11CSqiaCgEAAEcCAAAIAAAAAAAAAAEAAACkgQAAAABtZXRhLnhtbFBLAQIeAwoA
    AAAAADd2d10AAAAAAAAAAAAAAAAJAAAAAAAAAAAAEADtQTABAABwcm9qZWN0cy9QSwECHgMKAAAAAAA3dnddAAAAAAAAAAAAAAAA
    EQAAAAAAAAAAABAA7UFXAQAAcHJvamVjdHMvR2VuZXJhbC9QSwECHgMKAAAAAAA3dnddAAAAAAAAAAAAAAAAGgAAAAAAAAAAABAA
    7UGGAQAAcHJvamVjdHMvR2VuZXJhbC8uZGJlYXZlci9QSwECHgMUAAIACAA3dnddBls7gGQAAAB8AAAALwAAAAAAAAABAAAApIG+
    AQAAcHJvamVjdHMvR2VuZXJhbC8uZGJlYXZlci9wcm9qZWN0LW1ldGFkYXRhLmpzb25QSwECHgMKAAIAAAA3dndd4bVaonABAABw
    AQAAMQAAAAAAAAAAAAAApIFvAgAAcHJvamVjdHMvR2VuZXJhbC8uZGJlYXZlci9jcmVkZW50aWFscy1jb25maWcuanNvblBLAQIe
    AwoAAgAAADd2d108IpyrLQAAAC0AAAAvAAAAAAAAAAEAAACkgS4EAABwcm9qZWN0cy9HZW5lcmFsLy5kYmVhdmVyL3Byb2plY3Qt
    c2V0dGluZ3MuanNvblBLAQIeAxQAAgAIADd2d115bAITZwQAAMgOAAArAAAAAAAAAAEAAACkgagEAABwcm9qZWN0cy9HZW5lcmFs
    Ly5kYmVhdmVyL2RhdGEtc291cmNlcy5qc29uUEsBAh4DCgAAAAAAN3Z3XQAAAAAAAAAAAAAAABsAAAAAAAAAAAAQAO1BWAkAAHBy
    b2plY3RzL0dlbmVyYWwvLnNldHRpbmdzL1BLAQIeAwoAAgAAADd2d10N6N5NNwAAADcAAAA7AAAAAAAAAAEAAACkgZEJAABwcm9q
    ZWN0cy9HZW5lcmFsLy5zZXR0aW5ncy9vcmcuZWNsaXBzZS5jb3JlLnJlc291cmNlcy5wcmVmc1BLAQIeAwoAAAAAADd2d10AAAAA
    AAAAAAAAAAAZAAAAAAAAAAAAEADtQSEKAABwcm9qZWN0cy9HZW5lcmFsL1NjcmlwdHMvUEsBAh4DCgAAAAAAN3Z3XQAAAAAAAAAA
    AAAAACMAAAAAAAAAAAAAAKSBWAoAAHByb2plY3RzL0dlbmVyYWwvU2NyaXB0cy9TY3JpcHQuc3FsUEsFBgAAAAAMAAwAsAMAAJkK
    AAAAAA==
    """, options: .ignoreUnknownCharacters)!

    func profile(_ r: DBeaverImport.Result, _ name: String) -> ConnectionProfile? {
        r.sources.first { $0.profile.name == name }?.profile
    }

    @Test func readsExportedProject() throws {
        let r = try DBeaverImport.parse(Self.dbp)
        #expect(r.sources.count == 4)
        #expect(r.skipped == ["DBeaver Sample Database (SQLite)"])

        // DBeaver 26.2 Redshift: provider "postgresql" + driver "postgres-redshift-jdbc" → PostgreSQL 접속, TLS 켬
        let rs = try #require(profile(r, "GodDB Redshift"))
        #expect(rs.kind == .postgres)
        #expect(rs.host == "example-cluster.abc123.ap-northeast-2.redshift.amazonaws.com" && rs.port == 5439)
        #expect(rs.database == "dev")
        #expect(rs.username == "awsuser")
        #expect(rs.useTLS)
        #expect(rs.group == "Docker Test")

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
        #expect(Set(a.sources.map(\.profile.id)).count == 4)
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
        #expect(r.sources.count == 4)
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
        #expect(users.count == 4)
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

    // Redshift: 새 DBeaver(postgresql + postgres-redshift-jdbc), 옛 DBeaver(generic + aws_redshift), URL 방식
    @Test func redshiftBecomesPostgresWithTLS() throws {
        let json = """
        {"connections": {
          "rs-new": { "provider": "postgresql", "driver": "postgres-redshift-jdbc", "name": "분석",
            "configuration": { "host": "example-cluster.abc123.ap-northeast-2.redshift.amazonaws.com", "port": "5439",
                               "database": "dev", "user": "analyst" } },
          "rs-old": { "provider": "generic", "driver": "aws_redshift_42", "name": "옛 분석",
            "configuration": { "host": "old.example.test", "database": "dev", "provider-properties": { "ssl": "false" } } },
          "rs-url": { "provider": "postgresql", "driver": "postgres-redshift-jdbc", "name": "주소 분석",
            "configuration": { "url": "jdbc:redshift://url.example.test:5440/sales", "configurationType": "URL" } }
        }}
        """
        let r = try DBeaverImport.parse(Data(json.utf8))
        #expect(r.skipped.isEmpty)
        let new = try #require(r.sources.first { $0.profile.name == "분석" }).profile
        #expect(new.kind == .postgres && new.port == 5439 && new.database == "dev" && new.username == "analyst")
        #expect(new.useTLS && new.tlsVerify)
        #expect(new.redshift && new.type == .redshift)
        let old = try #require(r.sources.first { $0.profile.name == "옛 분석" }).profile
        #expect(old.kind == .postgres && old.port == 5439)
        #expect(!old.useTLS)
        let url = try #require(r.sources.first { $0.profile.name == "주소 분석" }).profile
        #expect(url.host == "url.example.test" && url.port == 5440 && url.database == "sales" && url.useTLS)

        let jdbc = try #require(DataGripImport.profile(fromJDBC: "jdbc:redshift://c.example.test/dev"))
        #expect(jdbc.kind == .postgres && jdbc.port == 5439 && jdbc.useTLS && jdbc.redshift)
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
